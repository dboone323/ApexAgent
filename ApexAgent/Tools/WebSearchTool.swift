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

            // Try Tavily AI Search second
            if let tavilyKey = getTavilyAPIKey(), !tavilyKey.isEmpty {
                if let tavilyResult = await searchTavily(query: arguments.query, count: count, apiKey: tavilyKey) {
                    return tavilyResult
                }
            }

            // Fallback to DuckDuckGo Instant Answer / Scraper / Weather fallback
            return await searchDuckDuckGo(query: arguments.query)
        }
    }

    // MARK: - Tavily Search

    private func migrateTavilyAPIKeyIfNeeded() {
        let defaults = UserDefaults.standard
        let legacyKey = "apex.tavilyAPIKey"
        guard let legacy = defaults.string(forKey: legacyKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty else {
            return
        }
        if let existing = KeychainManager.get(key: "tavilyAPIKey"), !existing.isEmpty {
            defaults.removeObject(forKey: legacyKey)
            return
        }
        guard KeychainManager.save(key: "tavilyAPIKey", value: legacy) else {
            AppLog.error(.security, "Tavily API key migration from UserDefaults to Keychain failed; legacy entry was retained.")
            return
        }
        defaults.removeObject(forKey: legacyKey)
    }

    func getTavilyAPIKey() -> String? {
        migrateTavilyAPIKeyIfNeeded()
        if let key = KeychainManager.get(key: "tavilyAPIKey"), !key.isEmpty {
            return key
        }
        return ProcessInfo.processInfo.environment["TAVILY_API_KEY"]
    }

    private func searchTavily(query: String, count: Int, apiKey: String) async -> String? {
        guard let url = URL(string: "https://api.tavily.com/search") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12

        let payload: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": count,
            "search_depth": "basic",
            "include_answer": true
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            var output = "🔎 Tavily Search results for: \"\(query)\"\n\n"

            if let aiAnswer = json?["answer"] as? String, !aiAnswer.isEmpty {
                output += "🤖 **AI Summary:** \(aiAnswer)\n\n"
            }

            if let results = json?["results"] as? [[String: Any]], !results.isEmpty {
                for (i, res) in results.prefix(count).enumerated() {
                    let title = res["title"] as? String ?? "No title"
                    let urlStr = res["url"] as? String ?? ""
                    let content = res["content"] as? String ?? ""
                    output += "\(i + 1). **\(title)**\n   URL: \(urlStr)\n   \(content)\n\n"
                }
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: Brave Search

    private func migrateBraveAPIKeyIfNeeded() {
        let defaults = UserDefaults.standard
        let legacyKey = "apex.braveSearchAPIKey"
        guard let legacy = defaults.string(forKey: legacyKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty else {
            return
        }
        if let existing = KeychainManager.get(key: "braveSearchAPIKey"), !existing.isEmpty {
            defaults.removeObject(forKey: legacyKey)
            return
        }
        guard KeychainManager.save(key: "braveSearchAPIKey", value: legacy) else {
            AppLog.error(.security, "Brave Search API key migration from UserDefaults to Keychain failed; legacy entry was retained.")
            return
        }
        defaults.removeObject(forKey: legacyKey)
    }

    func getBraveAPIKey() -> String? {
        migrateBraveAPIKeyIfNeeded()
        // Check Keychain first (set via Settings panel → KeychainManager)
        if let key = KeychainManager.get(key: "braveSearchAPIKey"), !key.isEmpty {
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
        // Try multiple endpoints — html.duckduckgo.com is frequently unreachable
        let endpoints = [
            "https://lite.duckduckgo.com/lite/",
            "https://html.duckduckgo.com/html/"
        ]

        for endpoint in endpoints {
            if let result = await scrapeDDGEndpoint(endpoint: endpoint, query: query) {
                return result
            }
        }

        // Weather-specific fallback: wttr.in provides free weather data as plain text
        if isWeatherQuery(query) {
            if let weather = await fetchWttrIn(query: query) {
                return weather
            }
        }

        return nil
    }

    private func isWeatherQuery(_ query: String) -> Bool {
        let lq = query.lowercased()
        let keywords = ["weather", "temperature", "forecast", "rain", "snow", "wind", "humidity", "degrees"]
        return keywords.contains(where: { lq.contains($0) })
    }

    private func fetchWttrIn(query: String) async -> String? {
        // Extract location from the query by removing weather-related words
        let lq = query.lowercased()
        let stripWords = ["what's", "what is", "the", "weather", "in", "current", "right now", "today", "forecast", "temperature"]
        var location = lq
        for word in stripWords {
            location = location.replacingOccurrences(of: word, with: "")
        }
        location = location.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "+")

        guard !location.isEmpty,
              let url = URL(string: "https://wttr.in/\(location)?format=4") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("curl/8.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty else {
                return nil
            }

            // Also fetch the detailed 1-day forecast
            var detailOutput = "🌤️ Weather for \"\(query)\":\n\n\(text)\n"

            if let detailURL = URL(string: "https://wttr.in/\(location)?format=%l:+%c+%t+%h+%w+%p+%P\\n") {
                var detailRequest = URLRequest(url: detailURL)
                detailRequest.setValue("curl/8.0", forHTTPHeaderField: "User-Agent")
                detailRequest.timeoutInterval = 8
                if let (detailData, _) = try? await URLSession.shared.data(for: detailRequest),
                   let detailText = String(data: detailData, encoding: .utf8),
                   !detailText.isEmpty {
                    detailOutput += "Details: \(detailText)\n"
                }
            }

            return detailOutput
        } catch {
            return nil
        }
    }

    private func scrapeDDGEndpoint(endpoint: String, query: String) async -> String? {
        guard let url = URL(string: endpoint) else { return nil }

        // Use POST for DuckDuckGo lite (it expects form-encoded queries)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)".data(using: .utf8)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }

            return parseSearchResultsHTML(html: html, query: query)
        } catch {
            return nil
        }
    }

    private func parseSearchResultsHTML(html: String, query: String) -> String? {
        var results: [(title: String, url: String, snippet: String)] = []
        let nsHtml = html as NSString

        // Try standard DDG HTML result format
        if let urlRegex = try? NSRegularExpression(pattern: "<a\\s+class=\"result__url\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators]),
           let snippetRegex = try? NSRegularExpression(pattern: "<a\\s+class=\"result__snippet\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators]) {
            let urlMatches = urlRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
            let snippetMatches = snippetRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))

            let count = min(urlMatches.count, snippetMatches.count)
            for i in 0..<count {
                var url = nsHtml.substring(with: urlMatches[i].range(at: 1))
                var title = nsHtml.substring(with: urlMatches[i].range(at: 2))
                var snippet = nsHtml.substring(with: snippetMatches[i].range(at: 1))
                title = cleanHTML(title)
                url = cleanHTML(url)
                snippet = cleanHTML(snippet)
                url = extractDDGRedirectURL(url)
                results.append((title: title, url: url, snippet: snippet))
            }
        }

        // Try lite DDG format if standard yielded nothing
        if results.isEmpty {
            if let liteUrlRegex = try? NSRegularExpression(pattern: "<a\\s+(?:class=\"result-link\"\\s+)?rel=\"nofollow\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators]),
               let liteSnippetRegex = try? NSRegularExpression(pattern: "<td\\s+class=\"result-snippet\"[^>]*>(.*?)</td>", options: [.dotMatchesLineSeparators]) {
                let liteUrlMatches = liteUrlRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
                let liteSnippetMatches = liteSnippetRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))

                let liteCount = min(liteUrlMatches.count, liteSnippetMatches.count)
                for i in 0..<liteCount {
                    var url = nsHtml.substring(with: liteUrlMatches[i].range(at: 1))
                    var title = nsHtml.substring(with: liteUrlMatches[i].range(at: 2))
                    var snippet = nsHtml.substring(with: liteSnippetMatches[i].range(at: 1))
                    title = cleanHTML(title)
                    url = cleanHTML(url)
                    snippet = cleanHTML(snippet)
                    url = extractDDGRedirectURL(url)
                    results.append((title: title, url: url, snippet: snippet))
                }
            }
        }

        // Generic fallback: find any <a href> with snippets nearby
        if results.isEmpty {
            if let genericRegex = try? NSRegularExpression(pattern: "<a[^>]+href=\"(https?://[^\"]+)\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators]) {
                let genericMatches = genericRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
                for match in genericMatches.prefix(10) {
                    let url = cleanHTML(nsHtml.substring(with: match.range(at: 1)))
                    let title = cleanHTML(nsHtml.substring(with: match.range(at: 2)))
                    guard !url.contains("duckduckgo.com"),
                          !title.isEmpty,
                          title.count > 3 else { continue }
                    results.append((title: title, url: extractDDGRedirectURL(url), snippet: ""))
                }
            }
        }

        if results.isEmpty { return nil }

        var output = "🦆 DuckDuckGo results for: \"\(query)\"\n\n"
        for (index, res) in results.prefix(8).enumerated() {
            output += "\(index + 1). **\(res.title)**\n   URL: \(res.url)\n"
            if !res.snippet.isEmpty {
                output += "   \(res.snippet)\n"
            }
            output += "\n"
        }
        return output
    }

    private func extractDDGRedirectURL(_ url: String) -> String {
        if url.contains("uddg=") {
            if let range = url.range(of: "uddg=") {
                let rawUrl = String(url[range.upperBound...])
                if let decodedUrl = rawUrl.removingPercentEncoding {
                    return decodedUrl.components(separatedBy: "&").first ?? decodedUrl
                }
            }
        }
        return url
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
