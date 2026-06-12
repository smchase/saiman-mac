import Foundation

/// Reddit search tool powered by Brave Search API.
/// Finds relevant Reddit threads using site:reddit.com filtering.
final class RedditSearchTool: Tool {
    let name = "reddit_search"

    let description = """
        Search Reddit for threads and discussions via Brave Search. \
        Returns titles, URLs, dates, and snippets. \
        Use reddit_read to fetch full thread content and comments. \
        Subreddit scoping works by adding subreddit names to the query \
        (soft filter, not exact). Recommended for better relevance.
        """

    let parameters: [ToolParameter] = [
        ToolParameter(
            name: "query",
            type: .string,
            description: "Search query."
        ),
        ToolParameter(
            name: "subreddits",
            type: .array,
            description: "Optional subreddit(s) to scope the search (e.g. ['askTO', 'toronto']). Added to query as keywords.",
            required: false
        ),
        ToolParameter(
            name: "freshness",
            type: .string,
            description: "Filter by recency: pd (24h), pw (week), pm (month), py (year). Default: no limit.",
            required: false
        )
    ]

    private let config = Config.shared

    func execute(arguments: String) async throws -> String {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.invalidArguments("Failed to parse arguments as JSON")
        }

        guard let query = args["query"] as? String, !query.isEmpty else {
            throw ToolError.invalidArguments("Missing or empty 'query' parameter.")
        }

        let subreddits = args["subreddits"] as? [String]
        let freshness = args["freshness"] as? String

        // Build search query
        var searchQuery = query
        if let subs = subreddits, !subs.isEmpty {
            searchQuery += " " + subs.joined(separator: " ")
        }
        searchQuery += " site:reddit.com"

        // Build URL
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        var queryItems = [
            URLQueryItem(name: "q", value: searchQuery),
            URLQueryItem(name: "count", value: "20")
        ]
        if let freshness = freshness {
            queryItems.append(URLQueryItem(name: "freshness", value: freshness))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ToolError.executionFailed("Failed to build search URL")
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(config.braveApiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.timeoutInterval = 30

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            Logger.shared.error("RedditSearch: Network error: \(error.localizedDescription)")
            throw ToolError.executionFailed("Network error: \(error.localizedDescription)")
        }

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 429 {
                throw ToolError.executionFailed("Brave rate limit hit")
            }
            guard httpResponse.statusCode == 200 else {
                Logger.shared.error("RedditSearch: HTTP \(httpResponse.statusCode)")
                throw ToolError.executionFailed("Brave returned HTTP \(httpResponse.statusCode)")
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]] else {
            return ""
        }

        if results.isEmpty {
            return ""
        }

        let scope = subreddits.map { "r/" + $0.joined(separator: "+") } ?? "all of Reddit"
        var output = "Reddit search (\(scope)): \(query)\n"
        output += String(repeating: "=", count: 60) + "\n\n"

        for (index, result) in results.enumerated() {
            let title = result["title"] as? String ?? "Untitled"
            let resultUrl = result["url"] as? String ?? ""
            let description = result["description"] as? String ?? ""
            let age = result["age"] as? String ?? ""

            // Extract subreddit from URL
            let subreddit = extractSubreddit(from: resultUrl) ?? "reddit"

            // Clean snippet
            var snippet = description
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            // Decode HTML entities
            if let entityData = snippet.data(using: .utf8),
               let decoded = try? NSAttributedString(
                   data: entityData,
                   options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                   documentAttributes: nil) {
                snippet = decoded.string
            }
            if snippet.count > 200 {
                snippet = String(snippet.prefix(200)) + "..."
            }

            output += "[\(index + 1)] \(title)\n"
            output += "    \(subreddit)"
            if !age.isEmpty {
                output += " | \(age)"
            }
            output += "\n    \(resultUrl)\n"
            if !snippet.isEmpty {
                output += "    \(snippet)\n"
            }
            output += "\n"
        }

        return output
    }

    private func extractSubreddit(from url: String) -> String? {
        let pattern = #"/r/([^/]+)/"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let range = Range(match.range(at: 1), in: url) else {
            return nil
        }
        return "r/" + String(url[range])
    }
}
