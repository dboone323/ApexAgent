import Foundation
import AppKit

// MARK: - Safe Web Search (ported from /tmp/macos26-agent, stripped of cloud keys)

enum WebSearchHelper {

    // MARK: - Public API

    static func search(query: String) async -> String {
        if let result = await searchZAI(query: query) {
            return result
        }
        if let result = await searchExa(query: query) {
            return result
        }
        if let result = await searchTavily(query: query) {
            return result
        }
        return await searchDuckDuckGo(query: query)
    }

    // MARK: - Providers

    private static func searchZAI(query: String) async -> String? {
        guard let apiKey = env("ZAI_API_KEY"), !apiKey.isEmpty else { return nil }
        guard let url = URL(string: "https://api.z.ai/api/paas/v4/web_search") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "search_engine": "search-prime",
            "search_query": query,
            "count": 10,
            "search_recency_filter": "noLimit"
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["search_result"] as? [[String: Any]], !results.isEmpty
            else { return nil }

            var output = ""
            for (i, result) in results.enumerated() {
                let title = result["title"] as? String ?? "Untitled"
                let resultUrl = result["link"] as? String ?? ""
                let content = result["content"] as? String ?? ""
                let media = result["media"] as? String ?? ""
                let publishDate = result["publish_date"] as? String ?? ""
                output += "\(i + 1). \(title)\n   \(resultUrl)\n"
                let meta = [media, publishDate].filter { !$0.isEmpty }
                if !meta.isEmpty {
                    output += "   [\(meta.joined(separator: " · "))]\n"
                }
                if !content.isEmpty {
                    output += "   \(content)\n"
                }
                output += "\n"
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func searchExa(query: String) async -> String? {
        guard let apiKey = env("EXA_API_KEY"), !apiKey.isEmpty else { return nil }
        guard let url = URL(string: "https://api.exa.ai/search") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "query": query,
            "type": "auto",
            "numResults": 10,
            "contents": ["text"]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]], !results.isEmpty
            else { return nil }

            var output = ""
            for (i, result) in results.enumerated().prefix(10) {
                let title = result["title"] as? String ?? "Untitled"
                let resultUrl = result["url"] as? String ?? ""
                let text = ((result["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                output += "\(i + 1). \(title)\n   \(resultUrl)\n"
                if !text.isEmpty {
                    output += "   \(text.prefix(300))\n"
                }
                output += "\n"
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func searchTavily(query: String) async -> String? {
        guard let apiKey = env("TAVILY_API_KEY"), !apiKey.isEmpty else { return nil }
        guard let url = URL(string: "https://api.tavily.com/search") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": 10,
            "include_answer": true
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]], !results.isEmpty
            else { return nil }

            var output = ""
            for (i, result) in results.enumerated() {
                let title = result["title"] as? String ?? "Untitled"
                let resultUrl = result["url"] as? String ?? ""
                let content = result["content"] as? String ?? ""
                output += "\(i + 1). \(title)\n   \(resultUrl)\n   \(content)\n\n"
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func searchDuckDuckGo(query: String) async -> String {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)")
        else {
            return "Error: failed to encode query"
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                return "Error: DuckDuckGo returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            }
            guard let html = String(data: data, encoding: .utf8) else { return "Error: failed to decode response" }
            return parseDuckDuckGo(html, limit: 10)
        } catch {
            return "Error: DuckDuckGo web search failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Parsing

    private static func parseDuckDuckGo(_ html: String, limit: Int) -> String {
        let pattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#
        let snippetPattern = #"class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)</a>"#

        guard let titleRegex = try? NSRegularExpression(pattern: pattern, options: []),
              let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [])
        else { return "No results found." }

        let nsHtml = html as NSString
        let titles = titleRegex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
        let snippets = snippetRegex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))

        var results: [(String, String, String)] = []
        for i in 0..<min(limit, titles.count) {
            let titleMatch = titles[i]
            let rawHref = nsHtml.substring(with: titleMatch.range(at: 1))
            let rawTitle = nsHtml.substring(with: titleMatch.range(at: 2))
            let resolvedURL = decodeDuckDuckGoHref(rawHref)
            let title = stripHTML(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            var snippet = ""
            if i < snippets.count, snippets[i].numberOfRanges > 1 {
                snippet = stripHTML(nsHtml.substring(with: snippets[i].range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !title.isEmpty && !resolvedURL.isEmpty {
                results.append((title, resolvedURL, snippet))
            }
        }

        guard !results.isEmpty else { return "No results found." }

        var output = ""
        for (i, result) in results.enumerated() {
            output += "\(i + 1). \(result.0)\n   \(result.1)\n"
            if !result.2.isEmpty { output += "   \(result.2)\n" }
            output += "\n"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeDuckDuckGoHref(_ href: String) -> String {
        let normalized = href.hasPrefix("//") ? "https:" + href : href
        guard let comps = URLComponents(string: normalized) else { return href }
        return comps.queryItems?.first(where: { $0.name == "uddg" })?.value?.removingPercentEncoding ?? normalized
    }

    private static func stripHTML(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func env(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]
        if let v = value, !v.isEmpty { return v }
        // Fallback: UserDefaults for tool-managed keys after <SECRET_a3c2b26c>(forKey: key), !k.isEmpty else { return nil }
        return nil
    }
}
