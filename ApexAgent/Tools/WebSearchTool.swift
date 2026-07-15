import Foundation
import FoundationModels

// MARK: - Web Search Tool (Brave + DuckDuckGo fallback)

struct WebSearchTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "web_search"
    let description = """
    Searches the web using Brave Search (primary) with DuckDuckGo as fallback. \
    Returns the top search results including titles, URLs, and text snippets. \
    Use this to find current information, documentation, news, or any web content.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The search query to look up on the web")
        var query: String

        @Guide(description: "Number of results to return", .range(1...10))
        var count: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let count = arguments.count ?? 5

            // Try Brave Search first
            if let braveKey = getBraveAPIKey(), !braveKey.isEmpty {
                if let braveResult = await searchBrave(query: arguments.query, count: count, apiKey: braveKey) {
                    return braveResult
                }
            }

            // Fallback to DuckDuckGo Instant Answer
            return await searchDuckDuckGo(query: arguments.query)
        }
    }

    // MARK: Brave Search

    private func getBraveAPIKey() -> String? {
        // Check UserDefaults first (set via Settings panel)
        if let key = UserDefaults.standard.string(forKey: "apex.braveSearchAPIKey"), !key.isEmpty {
            return key
        }
        // Check environment variable
        return ProcessInfo.processInfo.environment["BRAVE_SEARCH_API_KEY"]
    }

    private func searchBrave(query: String, count: Int, apiKey: String) async -> String? {
        guard var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "\(count)"),
            URLQueryItem(name: "text_decorations", value: "false"),
            URLQueryItem(name: "result_filter", value: "web")
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        var delay: Double = 1.0
        for attempt in 0...2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    throw NSError(domain: "BraveSearch", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
                }

                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let webResults = json?["web"] as? [String: Any],
                      let results = webResults["results"] as? [[String: Any]] else {
                    return nil
                }

                var output = "🔍 Brave Search results for: \"\(query)\"\n\n"
                for (i, result) in results.prefix(count).enumerated() {
                    let title = result["title"] as? String ?? "No title"
                    let url = result["url"] as? String ?? ""
                    let description = result["description"] as? String ?? "No description"
                    output += "\(i + 1). **\(title)**\n   URL: \(url)\n   \(description)\n\n"
                }

                return output.isEmpty ? nil : output
            } catch {
                if attempt == 2 {
                    return nil
                }
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                delay *= 2.0
            }
        }
        return nil
    }

    // MARK: DuckDuckGo Fallback

    private func searchDuckDuckGo(query: String) async -> String {
        guard var components = URLComponents(string: "https://api.duckduckgo.com/") else {
            return "ERROR: Could not construct search URL"
        }

        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]

        guard let url = components.url else {
            return "ERROR: Invalid search URL"
        }

        var request = URLRequest(url: url)
        request.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            var output = "🦆 DuckDuckGo results for: \"\(query)\"\n\n"
            var hasContent = false

            // Abstract (instant answer)
            if let abstract = json?["Abstract"] as? String, !abstract.isEmpty {
                let source = json?["AbstractSource"] as? String ?? ""
                let abstractURL = json?["AbstractURL"] as? String ?? ""
                output += "**\(source):** \(abstract)\nSource: \(abstractURL)\n\n"
                hasContent = true
            }

            // Related topics
            if let topics = json?["RelatedTopics"] as? [[String: Any]], !topics.isEmpty {
                var topicsAdded = 0
                for topic in topics.prefix(5) {
                    if let text = topic["Text"] as? String,
                       let firstURL = topic["FirstURL"] as? String {
                        if topicsAdded == 0 {
                            output += "**Related Topics:**\n"
                        }
                        output += "\(topicsAdded + 1). \(text)\n   \(firstURL)\n\n"
                        topicsAdded += 1
                        hasContent = true
                    }
                }
            }

            if !hasContent {
                if let scraped = await scrapeDuckDuckGoHTML(query: query) {
                    return scraped
                }
                output += "No instant answer found. Try a more specific query or use the shell tool to run a web search via curl."
            }

            return output
        } catch {
            if let scraped = await scrapeDuckDuckGoHTML(query: query) {
                return scraped
            }
            return "ERROR: Search failed — \(error.localizedDescription)"
        }
    }

    private func scrapeDuckDuckGoHTML(query: String) async -> String? {
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return nil }

            var results: [(title: String, url: String, snippet: String)] = []
            let nsHtml = html as NSString

            let urlRegex = try NSRegularExpression(pattern: "<a\\s+class=\"result__url\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators])
            let snippetRegex = try NSRegularExpression(pattern: "<a\\s+class=\"result__snippet\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators])

            let urlMatches = urlRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
            let snippetMatches = snippetRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))

            let count = min(urlMatches.count, snippetMatches.count)
            for i in 0..<count {
                let urlMatch = urlMatches[i]
                let snippetMatch = snippetMatches[i]

                var url = nsHtml.substring(with: urlMatch.range(at: 1))
                var title = nsHtml.substring(with: urlMatch.range(at: 2))
                var snippet = nsHtml.substring(with: snippetMatch.range(at: 1))

                title = cleanHTML(title)
                url = cleanHTML(url)
                snippet = cleanHTML(snippet)

                if url.contains("uddg=") {
                    if let range = url.range(of: "uddg=") {
                        let rawUrl = String(url[range.upperBound...])
                        if let decodedUrl = rawUrl.removingPercentEncoding {
                            url = decodedUrl.components(separatedBy: "&").first ?? decodedUrl
                        }
                    }
                }

                results.append((title: title, url: url, snippet: snippet))
            }

            if results.isEmpty {
                let liteUrlRegex = try NSRegularExpression(pattern: "<a\\s+class=\"result-link\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators])
                let liteSnippetRegex = try NSRegularExpression(pattern: "<td\\s+class=\"result-snippet\"[^>]*>(.*?)</td>", options: [.dotMatchesLineSeparators])

                let liteUrlMatches = liteUrlRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
                let liteSnippetMatches = liteSnippetRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))

                let liteCount = min(liteUrlMatches.count, liteSnippetMatches.count)
                for i in 0..<liteCount {
                    let urlMatch = liteUrlMatches[i]
                    let snippetMatch = liteSnippetMatches[i]

                    var url = nsHtml.substring(with: urlMatch.range(at: 1))
                    var title = nsHtml.substring(with: urlMatch.range(at: 2))
                    var snippet = nsHtml.substring(with: snippetMatch.range(at: 1))

                    title = cleanHTML(title)
                    url = cleanHTML(url)
                    snippet = cleanHTML(snippet)

                    if url.contains("uddg=") {
                        if let range = url.range(of: "uddg=") {
                            let rawUrl = String(url[range.upperBound...])
                            if let decodedUrl = rawUrl.removingPercentEncoding {
                                url = decodedUrl.components(separatedBy: "&").first ?? decodedUrl
                            }
                        }
                    }

                    results.append((title: title, url: url, snippet: snippet))
                }
            }

            if results.isEmpty { return nil }

            var output = "🦆 DuckDuckGo scraped results for: \"\(query)\"\n\n"
            for (index, res) in results.enumerated() {
                output += "\(index + 1). **\(res.title)**\n   URL: \(res.url)\n   \(res.snippet)\n\n"
            }
            return output
        } catch {
            return nil
        }
    }

    private func cleanHTML(_ input: String) -> String {
        var cleaned = input.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            "&quot;": "\"",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&apos;": "'",
            "&#x27;": "'",
            "&#x2F;": "/",
            "&#39;": "'",
            "&nbsp;": " "
        ]
        for (entity, char) in entities {
            cleaned = cleaned.replacingOccurrences(of: entity, with: char)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
