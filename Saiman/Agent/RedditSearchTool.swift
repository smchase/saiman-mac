import Foundation

/// Reddit search tool using Reddit's RSS feed.
/// Finds relevant Reddit threads via Reddit's search endpoint.
final class RedditSearchTool: Tool {
    let name = "reddit_search"

    let description = """
        Search Reddit for threads and discussions. Returns titles, URLs, dates, \
        and body snippets. Use reddit_read to fetch full thread content and comments. \
        Use the subreddits field to filter to known relevant subreddit(s).
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
            description: "Optional subreddit(s) to scope the search (e.g. ['askTO', 'toronto']). Omit for global search.",
            required: false
        ),
        ToolParameter(
            name: "sort",
            type: .string,
            description: "Sort order: relevance, new, top, comments. Default: relevance.",
            required: false
        ),
        ToolParameter(
            name: "time_filter",
            type: .string,
            description: "Time window: all, year, month, week, day. Default: all.",
            required: false
        )
    ]

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"

    func execute(arguments: String) async throws -> String {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.invalidArguments("Failed to parse arguments as JSON")
        }

        guard let query = args["query"] as? String, !query.isEmpty else {
            throw ToolError.invalidArguments("Missing or empty 'query' parameter.")
        }

        let subreddits = args["subreddits"] as? [String]
        let sort = args["sort"] as? String
        let timeFilter = args["time_filter"] as? String

        // Build URL
        var components: URLComponents
        if let subs = subreddits, !subs.isEmpty {
            let subPath = subs.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }.joined(separator: "+")
            components = URLComponents(string: "https://www.reddit.com/r/\(subPath)/search.rss")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "restrict_sr", value: "on"),
                URLQueryItem(name: "type", value: "link")
            ]
        } else {
            components = URLComponents(string: "https://www.reddit.com/search.rss")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "link")
            ]
        }

        if let sort = sort {
            components.queryItems?.append(URLQueryItem(name: "sort", value: sort))
        }
        if let timeFilter = timeFilter {
            components.queryItems?.append(URLQueryItem(name: "t", value: timeFilter))
        }

        guard let url = components.url else {
            throw ToolError.invalidArguments("Failed to build search URL")
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
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
                return "Reddit rate limit hit. Try again in a moment."
            }
            guard httpResponse.statusCode == 200 else {
                Logger.shared.error("RedditSearch: HTTP \(httpResponse.statusCode)")
                throw ToolError.executionFailed("Reddit returned HTTP \(httpResponse.statusCode)")
            }
        }

        guard let xmlString = String(data: responseData, encoding: .utf8) else {
            throw ToolError.executionFailed("Failed to decode Reddit response")
        }

        // Parse Atom XML
        let parser = RedditRSSParser(xml: xmlString)
        let entries = parser.parse()

        if entries.isEmpty {
            return "No Reddit threads found for: \(query)"
        }

        let scope = subreddits.map { "r/" + $0.joined(separator: "+") } ?? "all of Reddit"
        var output = "Reddit search (\(scope)): \(query)\n"
        output += String(repeating: "=", count: 60) + "\n\n"

        for (index, entry) in entries.enumerated() {
            output += "[\(index + 1)] \(entry.title)\n"
            output += "    \(entry.subreddit) | \(entry.author) | \(entry.date)\n"
            output += "    \(entry.link)\n"
            if !entry.snippet.isEmpty {
                output += "    \(entry.snippet)\n"
            }
            output += "\n"
        }

        return output
    }
}

// MARK: - RSS Parser

private struct RSSEntry {
    let title: String
    let link: String
    let date: String
    let author: String
    let subreddit: String
    let snippet: String
}

private class RedditRSSParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var entries: [RSSEntry] = []

    private var inEntry = false
    private var currentElement = ""
    private var currentTitle = ""
    private var currentLink = ""
    private var currentUpdated = ""
    private var currentAuthorName = ""
    private var currentCategory = ""
    private var currentContent = ""
    private var inAuthor = false

    init(xml: String) {
        self.xml = xml
    }

    func parse() -> [RSSEntry] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName

        if elementName == "entry" {
            inEntry = true
            currentTitle = ""
            currentLink = ""
            currentUpdated = ""
            currentAuthorName = ""
            currentCategory = ""
            currentContent = ""
        } else if elementName == "link" && inEntry {
            currentLink = attributes["href"] ?? ""
        } else if elementName == "category" && inEntry {
            currentCategory = attributes["label"] ?? ""
        } else if elementName == "author" {
            inAuthor = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inEntry else { return }

        if currentElement == "title" {
            currentTitle += string
        } else if currentElement == "updated" {
            currentUpdated += string
        } else if currentElement == "name" && inAuthor {
            currentAuthorName += string
        } else if currentElement == "content" {
            currentContent += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "author" {
            inAuthor = false
        } else if elementName == "entry" {
            inEntry = false

            let snippet = extractSnippet(from: currentContent)
            let date = String(currentUpdated.prefix(10))

            entries.append(RSSEntry(
                title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                link: currentLink,
                date: date,
                author: currentAuthorName.trimmingCharacters(in: .whitespacesAndNewlines),
                subreddit: currentCategory,
                snippet: snippet
            ))
        }

        currentElement = ""
    }

    private func extractSnippet(from htmlContent: String) -> String {
        var text = htmlContent
        // Strip HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode common entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&#x27;", with: "'")
        // Collapse whitespace
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        // Remove "submitted by" boilerplate
        if let range = text.range(of: "submitted by /u/", options: .caseInsensitive) {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if text.isEmpty { return "" }
        if text.count > 200 {
            return String(text.prefix(200)) + "..."
        }
        return text
    }
}
