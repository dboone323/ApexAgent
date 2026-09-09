import Foundation
import FoundationModels
import WebKit

// MARK: - Browser Manager (Main Actor bound)

@MainActor
class BrowserManager: NSObject, WKNavigationDelegate {
    static let shared = BrowserManager()
    
    private var webView: WKWebView?
    private var navigationContinuation: CheckedContinuation<String, Error>?
    private var webViewConfig: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        return config
    }()
    
    var isPersistent: Bool { true }
    var dataStore: WKWebsiteDataStore? { webViewConfig.websiteDataStore }
    
    private var offscreenWindow: NSWindow?
    private var loadedDocumentHtml: String?
    private var loadedDocumentTitle: String?
    
    func cleanup() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        offscreenWindow?.contentView = nil
        offscreenWindow = nil
        webView = nil
        navigationContinuation = nil
        loadedDocumentHtml = nil
        loadedDocumentTitle = nil
    }
    
    func initializeWebView() {
        if webView == nil {
            let config = WKWebViewConfiguration()
            let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
            config.websiteDataStore = isTesting ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore.default()
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
            wv.navigationDelegate = self
            let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.contentView = wv
            self.offscreenWindow = win
            self.webView = wv
        }
    }
    
    func navigate(to urlString: String) async throws -> String {
        // Ensure urlString has a scheme
        var finalUrlStr = urlString
        if !finalUrlStr.lowercased().hasPrefix("http://") && !finalUrlStr.lowercased().hasPrefix("https://") && !finalUrlStr.lowercased().hasPrefix("data:") {
            finalUrlStr = "https://" + finalUrlStr
        }
        
        guard let url = URL(string: finalUrlStr) else {
            throw NSError(domain: "BrowserManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(urlString)"])
        }

        if finalUrlStr.hasPrefix("data:text/html,") {
            let rawHtml = String(finalUrlStr.dropFirst("data:text/html,".count))
            let html = rawHtml.removingPercentEncoding ?? rawHtml
            self.loadedDocumentHtml = html
            var title = "No Title"
            if let startRange = html.range(of: "<title>", options: .caseInsensitive),
               let endRange = html.range(of: "</title>", options: .caseInsensitive, range: startRange.upperBound..<html.endIndex) {
                title = String(html[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            self.loadedDocumentTitle = title
            return "✅ Successfully loaded page: '\(title)'"
        }

        initializeWebView()
        guard let webView = webView else {
            throw NSError(domain: "BrowserManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebView not initialized"])
        }
        
        if let oldContinuation = navigationContinuation {
            navigationContinuation = nil
            oldContinuation.resume(throwing: NSError(domain: "BrowserManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Navigation cancelled by subsequent load"]))
        }

        let timer = Task {
            try? await Task.sleep(for: .seconds(2))
            self.cancelNavigationOnTimeout()
        }
        
        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                self.navigationContinuation = continuation
                webView.load(URLRequest(url: url))
            }
            timer.cancel()
            return result
        } catch {
            timer.cancel()
            throw error
        }
    }

    private func cancelNavigationOnTimeout() {
        if let cont = navigationContinuation {
            navigationContinuation = nil
            webView?.stopLoading()
            cont.resume(throwing: NSError(domain: "BrowserManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "Navigation timed out after 2 seconds"]))
        }
    }
    
    private static func stripHtmlTags(from html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"(?is)<script.*?>.*?</script>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?is)<style.*?>.*?</style>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</(p|div|h[1-6]|li|tr)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func scrapePage() async throws -> String {
        if let testHtml = loadedDocumentHtml {
            return Self.stripHtmlTags(from: testHtml)
        }

        guard let webView = webView else {
            return "ERROR: Browser has not been opened yet. Run open_url first."
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("document.body.innerText") { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as? String ?? "")
                }
            }
        }
    }

    func extractLinks() async throws -> String {
        if let testHtml = loadedDocumentHtml {
            let pattern = #"<a\s+(?:[^>]*?\s+)?href="([^"]*)"[^>]*>(.*?)<\/a>"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let nsHtml = testHtml as NSString
                let matches = regex.matches(in: testHtml, range: NSRange(location: 0, length: nsHtml.length))
                var links: [String] = []
                for match in matches {
                    let href = nsHtml.substring(with: match.range(at: 1))
                    let text = nsHtml.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    links.append("[\(text)](\(href))")
                }
                return links.isEmpty ? "No links found." : links.joined(separator: "\n")
            }
        }

        guard let webView = webView else {
            return "ERROR: Browser has not been opened yet. Run open_url first."
        }

        let js = """
        (function() {
            var links = Array.from(document.querySelectorAll('a[href]')).slice(0, 50).map(function(a) {
                var text = a.innerText.trim() || a.getAttribute('aria-label') || a.getAttribute('title') || '';
                return '[' + text + '](' + a.href + ')';
            });
            return links.join('\\n');
        })()
        """
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as? String ?? "No links found.")
                }
            }
        }
    }

    func evaluateScript(_ script: String) async throws -> String {
        guard let webView = webView else {
            return "ERROR: Browser has not been opened yet. Run open_url first."
        }

        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let result = result {
                    continuation.resume(returning: "\(result)")
                } else {
                    continuation.resume(returning: "Script executed successfully (null return).")
                }
            }
        }
    }
    
    func clickElement(selector: String) async throws -> String {
        guard let webView = webView else {
            return "ERROR: Browser has not been opened yet. Run open_url first."
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let js = """
            (function() {
                var el = document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))');
                if (el) {
                    el.click();
                    return "✅ Clicked element matching selector: \(selector)";
                } else {
                    return "ERROR: Element matching selector '\(selector)' not found.";
                }
            })()
            """
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as? String ?? "ERROR: Element not found")
                }
            }
        }
    }
    
    func inputText(selector: String, text: String) async throws -> String {
        guard let webView = webView else {
            return "ERROR: Browser has not been opened yet. Run open_url first."
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
            let escapedSelector = selector.replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function() {
                var el = document.querySelector('\(escapedSelector)');
                if (el) {
                    el.value = '\(escapedText)';
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    return "✅ Successfully set input value for \(selector) to '\(text)'";
                } else {
                    return "ERROR: Element matching selector '\(selector)' not found.";
                }
            })()
            """
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as? String ?? "ERROR: Element not found")
                }
            }
        }
    }

    func clearSession() async throws -> String {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let date = Date(timeIntervalSince1970: 0)
        await store.removeData(ofTypes: types, modifiedSince: date)
        cleanup()
        return "✅ Browser session and stored website data cleared."
    }
    
    // MARK: - WKNavigationDelegate
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.title") { [weak self] result, error in
            guard let self = self else { return }
            if let continuation = self.navigationContinuation {
                self.navigationContinuation = nil
                let title = result as? String ?? "No Title"
                continuation.resume(returning: "✅ Successfully loaded page: '\(title)'")
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let continuation = navigationContinuation {
            navigationContinuation = nil
            continuation.resume(throwing: error)
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let continuation = navigationContinuation {
            navigationContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let continuation = navigationContinuation {
            navigationContinuation = nil
            continuation.resume(throwing: NSError(domain: "BrowserManager", code: -5, userInfo: [NSLocalizedDescriptionKey: "Web content process terminated."]))
        }
    }
}

// MARK: - Browser Automation Tool

struct BrowserAutomationTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "control_browser"
    let description = "Controls a persistent headless web browser (WebKit-based) to open pages, scrape content, click elements, fill forms, extract links, evaluate JavaScript, and manage sessions."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The action to perform: 'open_url', 'scrape_page', 'extract_links', 'click_element', 'input_text', 'evaluate_script', 'clear_session'")
        var action: String
        
        @Guide(description: "The URL to navigate to - required for open_url")
        var url: String?
        
        @Guide(description: "CSS selector for the target element - required for click_element and input_text")
        var selector: String?
        
        @Guide(description: "The text value to input or JavaScript snippet to evaluate")
        var textValue: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: "Automating browser navigation and interactions") {
            switch arguments.action {
            case "open_url":
                guard let url = arguments.url else {
                    return "ERROR: url is required for open_url action."
                }
                do {
                    return try await BrowserManager.shared.navigate(to: url)
                } catch {
                    return "ERROR: Failed to load URL: \(error.localizedDescription)"
                }
                
            case "scrape_page":
                return try await BrowserManager.shared.scrapePage()

            case "extract_links":
                return try await BrowserManager.shared.extractLinks()

            case "evaluate_script":
                guard let script = arguments.textValue else {
                    return "ERROR: textValue containing JavaScript is required for evaluate_script action."
                }
                return try await BrowserManager.shared.evaluateScript(script)
                
            case "click_element":
                guard let selector = arguments.selector else {
                    return "ERROR: selector is required for click_element action."
                }
                return try await BrowserManager.shared.clickElement(selector: selector)
                
            case "input_text":
                guard let selector = arguments.selector else {
                    return "ERROR: selector is required for input_text action."
                }
                guard let textValue = arguments.textValue else {
                    return "ERROR: textValue is required for input_text action."
                }
                return try await BrowserManager.shared.inputText(selector: selector, text: textValue)

            case "clear_session":
                return try await BrowserManager.shared.clearSession()
                
            default:
                return "ERROR: Unknown action '\(arguments.action)'. Supported: open_url, scrape_page, extract_links, click_element, input_text, evaluate_script, clear_session"
            }
        }
    }
}
