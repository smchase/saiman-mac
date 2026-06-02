import Foundation

// MARK: - Reddit API Types

struct RedditThread {
    let title: String
    let selftext: String
    let author: String
    let score: Int
    let numComments: Int
    let subreddit: String
    let createdUtc: Date
    let url: String
    let comments: [RedditComment]
}

struct RedditComment {
    let author: String
    let body: String
    let score: Int
    let depth: Int
    let replies: [RedditComment]
}

// MARK: - Reddit Client

final class RedditClient {
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"

    /// Fetch a Reddit thread with comments by parsing old.reddit.com HTML
    func fetchThread(url: String) async throws -> RedditThread {
        let oldUrl = toOldRedditUrl(url)

        guard let requestUrl = URL(string: oldUrl) else {
            Logger.shared.error("Reddit: Invalid URL format: \(url)")
            throw RedditError.parseError("Invalid URL format")
        }

        var request = URLRequest(url: requestUrl)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            Logger.shared.error("Reddit: Network error for \(url): \(error.localizedDescription)")
            throw RedditError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.shared.error("Reddit: Invalid response type for \(url)")
            throw RedditError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 404:
            Logger.shared.error("Reddit: Thread not found (404): \(url)")
            throw RedditError.threadNotFound(url)
        case 429:
            Logger.shared.error("Reddit: Rate limited (429)")
            throw RedditError.rateLimited
        case 403:
            Logger.shared.error("Reddit: Forbidden (403): \(url)")
            throw RedditError.apiError(statusCode: 403)
        default:
            Logger.shared.error("Reddit: HTTP \(httpResponse.statusCode) for \(url)")
            throw RedditError.apiError(statusCode: httpResponse.statusCode)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw RedditError.parseError("Failed to decode response as UTF-8")
        }

        guard html.contains("commentarea") else {
            Logger.shared.error("Reddit: No comment area in response for \(url) (\(data.count) bytes)")
            throw RedditError.parseError("No comment data in response")
        }

        do {
            return try parseThread(html: html, originalUrl: url)
        } catch {
            Logger.shared.error("Reddit: Parse error for \(url): \(error.localizedDescription)")
            throw error
        }
    }

    /// Fetch multiple threads in parallel
    func fetchThreads(urls: [String]) async throws -> [Result<RedditThread, Error>] {
        await withTaskGroup(of: (Int, Result<RedditThread, Error>).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        let thread = try await self.fetchThread(url: url)
                        return (index, .success(thread))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            var results = [(Int, Result<RedditThread, Error>)]()
            for await result in group {
                results.append(result)
            }

            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    // MARK: - Private Methods

    private func toOldRedditUrl(_ url: String) -> String {
        var clean = url
        if let queryIndex = clean.firstIndex(of: "?") {
            clean = String(clean[..<queryIndex])
        }
        while clean.hasSuffix("/") {
            clean.removeLast()
        }
        // Convert any reddit domain to old.reddit.com
        let pattern = #"https?://(?:www\.|old\.|np\.|new\.|m\.)?reddit\.com"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(clean.startIndex..., in: clean)
            clean = regex.stringByReplacingMatches(in: clean, range: range, withTemplate: "https://old.reddit.com")
        }
        return clean + "/?sort=top&limit=200"
    }

    // MARK: - HTML Parsing

    private func parseThread(html: String, originalUrl: String) throws -> RedditThread {
        // Extract post metadata
        let postPattern = #"data-type="link"[^>]*data-author="([^"]*)"[^>]*data-subreddit="([^"]*)"[^>]*data-timestamp="(\d+)"[^>]*data-comments-count="(\d+)"[^>]*data-score="([^"]*)"#
        guard let postMatch = html.firstMatch(pattern: postPattern) else {
            throw RedditError.parseError("Failed to find post metadata")
        }

        let author = postMatch[1]
        let subreddit = postMatch[2]
        let timestampMs = Double(postMatch[3]) ?? 0
        let numComments = Int(postMatch[4]) ?? 0
        let score = Int(postMatch[5]) ?? 0

        // Title
        let titlePattern = #"<a class="title[^"]*"[^>]*>([^<]+)</a>"#
        let title = html.firstMatch(pattern: titlePattern)?[1].htmlDecoded ?? "Untitled"

        // Selftext (inside the post's form)
        var selftext = ""
        let postFormPattern = #"<form[^>]*id="form-t3_[^"]*"[^>]*>.*?<div class="md">(.*?)</div>\s*</div>\s*</form>"#
        if let formMatch = html.firstMatch(pattern: postFormPattern, options: .dotMatchesLineSeparators) {
            selftext = formMatch[1].htmlToText
        }

        let createdUtc = Date(timeIntervalSince1970: timestampMs / 1000)

        // Parse comments
        let comments = parseComments(html: html)

        return RedditThread(
            title: title.htmlDecoded,
            selftext: selftext,
            author: author,
            score: score,
            numComments: numComments,
            subreddit: subreddit,
            createdUtc: createdUtc,
            url: originalUrl,
            comments: comments
        )
    }

    private func parseComments(html: String) -> [RedditComment] {
        guard let commentAreaStart = html.range(of: "commentarea") else {
            return []
        }
        let commentHtml = String(html[commentAreaStart.lowerBound...])

        // Build depth map via stack-based div tracking
        let depthMap = buildDepthMap(commentHtml: commentHtml)

        // Find all comments and extract content
        let anchorPattern = #"data-fullname="(t1_[^"]+)"[^>]*data-type="comment""#
        let anchorRegex = try! NSRegularExpression(pattern: anchorPattern)
        let fullRange = NSRange(commentHtml.startIndex..., in: commentHtml)
        let anchorMatches = anchorRegex.matches(in: commentHtml, range: fullRange)

        var results: [RedditComment] = []
        for (i, match) in anchorMatches.enumerated() {
            let fullnameRange = Range(match.range(at: 1), in: commentHtml)!
            let fullname = String(commentHtml[fullnameRange])

            // Get chunk from this comment to the next
            let startIdx = commentHtml.index(commentHtml.startIndex, offsetBy: match.range.location)
            let endIdx: String.Index
            if i + 1 < anchorMatches.count {
                endIdx = commentHtml.index(commentHtml.startIndex, offsetBy: anchorMatches[i + 1].range.location)
            } else {
                endIdx = commentHtml.index(startIdx, offsetBy: min(10000, commentHtml.distance(from: startIdx, to: commentHtml.endIndex)))
            }
            let chunk = String(commentHtml[startIdx..<endIdx])

            // Author
            guard let authorMatch = chunk.firstMatch(pattern: #"data-author="([^"]+)""#) else { continue }
            let commentAuthor = authorMatch[1]

            // Score
            var scoreValue = 0
            if let scoreMatch = chunk.firstMatch(pattern: #"<span class="score unvoted" title="([^"]*)"#) {
                scoreValue = Int(scoreMatch[1]) ?? 0
            } else if let scoreMatch = chunk.firstMatch(pattern: #"<span class="score [^"]*" title="([^"]*)"#) {
                scoreValue = Int(scoreMatch[1]) ?? 0
            }

            // Body
            let bodyPattern = #"<div class="usertext-body[^"]*"[^>]*>\s*<div class="md">(.*?)</div>\s*</div>\s*</form>"#
            guard let bodyMatch = chunk.firstMatch(pattern: bodyPattern, options: .dotMatchesLineSeparators) else { continue }
            let body = bodyMatch[1].htmlToText

            // Skip deleted
            if commentAuthor == "[deleted]" && (body == "[deleted]" || body == "[removed]") {
                continue
            }

            let depth = depthMap[fullname] ?? 0

            results.append(RedditComment(
                author: commentAuthor,
                body: body,
                score: scoreValue,
                depth: depth,
                replies: []  // Flat list; depth encodes nesting
            ))
        }

        return results
    }

    /// Build a map of comment fullname -> depth using stack-based div tracking
    private func buildDepthMap(commentHtml: String) -> [String: Int] {
        // Find all relevant markers
        let divOpenRegex = try! NSRegularExpression(pattern: #"<div[\s>]"#)
        let divCloseRegex = try! NSRegularExpression(pattern: #"</div>"#)
        let stOpenRegex = try! NSRegularExpression(pattern: #"<div[^>]*id="(siteTable_t[13]_[^"]+)""#)
        let commentRegex = try! NSRegularExpression(pattern: #"data-fullname="(t1_[^"]+)"[^>]*data-type="comment"[^>]*data-author="([^"]+)""#)

        let fullRange = NSRange(commentHtml.startIndex..., in: commentHtml)

        // Collect events
        struct Event {
            let position: Int
            let type: EventType
            enum EventType {
                case divOpen, divClose, stOpen(String), comment(String)
            }
        }

        var events: [Event] = []

        for match in divOpenRegex.matches(in: commentHtml, range: fullRange) {
            events.append(Event(position: match.range.location, type: .divOpen))
        }
        for match in divCloseRegex.matches(in: commentHtml, range: fullRange) {
            events.append(Event(position: match.range.location, type: .divClose))
        }
        for match in stOpenRegex.matches(in: commentHtml, range: fullRange) {
            let idRange = Range(match.range(at: 1), in: commentHtml)!
            let stId = String(commentHtml[idRange])
            events.append(Event(position: match.range.location, type: .stOpen(stId)))
        }
        for match in commentRegex.matches(in: commentHtml, range: fullRange) {
            let fnRange = Range(match.range(at: 1), in: commentHtml)!
            let fullname = String(commentHtml[fnRange])
            events.append(Event(position: match.range.location, type: .comment(fullname)))
        }

        events.sort { $0.position < $1.position }

        // Process events with stack
        var divDepth = 0
        var stStack: [(String, Int)] = []  // (siteTable ID, div depth when opened)
        var commentParents: [String: String] = [:]  // fullname -> parent siteTable ID

        for event in events {
            switch event.type {
            case .divOpen:
                divDepth += 1
            case .divClose:
                while let last = stStack.last, last.1 >= divDepth {
                    stStack.removeLast()
                }
                divDepth -= 1
            case .stOpen(let stId):
                stStack.append((stId, divDepth))
            case .comment(let fullname):
                if let stId = stStack.last?.0 {
                    commentParents[fullname] = stId
                }
            }
        }

        // Resolve depths from parent chain
        var depthMemo: [String: Int] = [:]

        func getDepth(_ fullname: String) -> Int {
            if let cached = depthMemo[fullname] { return cached }
            guard let parentSt = commentParents[fullname] else {
                depthMemo[fullname] = 0
                return 0
            }
            if parentSt.hasPrefix("siteTable_t3_") {
                depthMemo[fullname] = 0
                return 0
            }
            let parentFn = parentSt.replacingOccurrences(of: "siteTable_", with: "")
            let d = getDepth(parentFn) + 1
            depthMemo[fullname] = d
            return d
        }

        for fullname in commentParents.keys {
            _ = getDepth(fullname)
        }

        return depthMemo
    }
}

// MARK: - Errors

enum RedditError: Error, LocalizedError {
    case invalidResponse
    case threadNotFound(String)
    case rateLimited
    case apiError(statusCode: Int)
    case parseError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Reddit. The thread may have been deleted or made private."
        case .threadNotFound(let url):
            return "Thread not found: \(url). It may have been deleted or the URL is incorrect."
        case .rateLimited:
            return "Reddit rate limit exceeded. Wait a few seconds before retrying."
        case .apiError(let statusCode):
            return "Reddit error (HTTP \(statusCode)). Try again or use fewer URLs."
        case .parseError(let message):
            return "Failed to parse Reddit response: \(message)."
        case .networkError(let message):
            return "Network error fetching Reddit: \(message)"
        }
    }
}

// MARK: - String Helpers

private extension String {
    var htmlDecoded: String {
        guard let data = self.data(using: .utf8) else { return self }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string
        }
        // Fallback: manual entity decoding
        return self
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
    }

    var htmlToText: String {
        var text = self
        // Block quotes
        text = text.replacingPattern(#"<blockquote>"#, with: "> ")
        text = text.replacingPattern(#"</blockquote>"#, with: "\n")
        // Paragraphs and line breaks
        text = text.replacingPattern(#"<p>"#, with: "")
        text = text.replacingPattern(#"</p>"#, with: "\n")
        text = text.replacingPattern(#"<br\s*/?>"#, with: "\n")
        // Lists
        text = text.replacingPattern(#"<li>"#, with: "- ")
        text = text.replacingPattern(#"</li>"#, with: "\n")
        // Links: use text if available, otherwise show URL
        text = text.replacingPattern(#"<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#, options: .dotMatchesLineSeparators) { match in
            let innerText = match[2].replacingPattern(#"<[^>]+>"#, with: "").trimmingCharacters(in: .whitespaces)
            return innerText.isEmpty ? match[1] : innerText
        }
        // Inline formatting
        text = text.replacingPattern(#"<(?:strong|b)>(.*?)</(?:strong|b)>"#, options: .dotMatchesLineSeparators, with: "$1")
        text = text.replacingPattern(#"<(?:em|i)>(.*?)</(?:em|i)>"#, options: .dotMatchesLineSeparators, with: "$1")
        text = text.replacingPattern(#"<code>([^<]*)</code>"#, with: "`$1`")
        text = text.replacingPattern(#"<pre>(.*?)</pre>"#, options: .dotMatchesLineSeparators, with: "$1")
        // Strip remaining tags
        text = text.replacingPattern(#"<[^>]+>"#, with: "")
        // Decode entities
        text = text.htmlDecoded
        // Clean up whitespace
        text = text.replacingPattern(#"\n{3,}"#, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func firstMatch(pattern: String, options: NSRegularExpression.Options = []) -> RegexResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(self.startIndex..., in: self)
        guard let match = regex.firstMatch(in: self, range: range) else { return nil }
        return RegexResult(match: match, string: self)
    }

    func replacingPattern(_ pattern: String, options: NSRegularExpression.Options = [], with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return self }
        let range = NSRange(self.startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: template)
    }

    func replacingPattern(_ pattern: String, options: NSRegularExpression.Options = [], using transform: (RegexResult) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return self }
        let range = NSRange(self.startIndex..., in: self)
        let matches = regex.matches(in: self, range: range)
        var result = self
        for match in matches.reversed() {
            let matchResult = RegexResult(match: match, string: self)
            let replacement = transform(matchResult)
            let matchRange = Range(match.range, in: self)!
            result.replaceSubrange(matchRange, with: replacement)
        }
        return result
    }
}

struct RegexResult {
    let match: NSTextCheckingResult
    let string: String

    subscript(index: Int) -> String {
        guard index < match.numberOfRanges else { return "" }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: string) else { return "" }
        return String(string[swiftRange])
    }
}
