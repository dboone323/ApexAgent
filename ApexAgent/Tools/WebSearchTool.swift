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

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
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
            return nil
        }
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

            // Abstract (instant answer)
            if let abstract = json?["Abstract"] as? String, !abstract.isEmpty {
                let source = json?["AbstractSource"] as? String ?? ""
                let abstractURL = json?["AbstractURL"] as? String ?? ""
                output += "**\(source):** \(abstract)\nSource: \(abstractURL)\n\n"
            }

            // Related topics
            if let topics = json?["RelatedTopics"] as? [[String: Any]] {
                output += "**Related Topics:**\n"
                for (i, topic) in topics.prefix(5).enumerated() {
                    if let text = topic["Text"] as? String,
                       let firstURL = topic["FirstURL"] as? String {
                        output += "\(i + 1). \(text)\n   \(firstURL)\n\n"
                    }
                }
            }

            if output == "🦆 DuckDuckGo results for: \"\(query)\"\n\n" {
                output += "No instant answer found. Try a more specific query or use the shell tool to run a web search via curl."
            }

            return output
        } catch {
            return "ERROR: Search failed — \(error.localizedDescription)"
        }
    }
}
