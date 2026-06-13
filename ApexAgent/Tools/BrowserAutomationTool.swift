import Foundation
import FoundationModels
import WebKit

// MARK: - Browser Manager (Main Actor bound)

@MainActor
class BrowserManager: NSObject, WKNavigationDelegate {
    static let shared = BrowserManager()
    
    private var webView: WKWebView?
    private var navigationContinuation: CheckedContinuation<String, Error>?
    
    func initializeWebView() {
        if webView == nil {
            let config = WKWebViewConfiguration()
            webView = WKWebView(frame: .zero, configuration: config)
            webView?.navigationDelegate = self
        }
    }
    
    func navigate(to urlString: String) async throws -> String {
        initializeWebView()
        guard let webView = webView else {
            throw NSError(domain: "BrowserManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebView not initialized"])
        }
        
        // Ensure urlString has a scheme
        var finalUrlStr = urlString
        if !finalUrlStr.lowercased().hasPrefix("http://") && !finalUrlStr.lowercased().hasPrefix("https://") {
            finalUrlStr = "https://" + finalUrlStr
        }
        
        guard let url = URL(string: finalUrlStr) else {
            throw NSError(domain: "BrowserManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(urlString)"])
        }
        
        if let oldContinuation = navigationContinuation {
            navigationContinuation = nil
            oldContinuation.resume(throwing: NSError(domain: "BrowserManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Navigation cancelled by subsequent load"]))
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.navigationContinuation = continuation
            webView.load(URLRequest(url: url))
        }
    }
    
    func scrapePage() async throws -> String {
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
}

// MARK: - Browser Automation Tool

struct BrowserAutomationTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "control_browser"
    let description = "Controls a headless, windowless web browser (Safari/WebKit based) to open pages, scrape content, click elements, and fill forms."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The action to perform: 'open_url', 'scrape_page', 'click_element', 'input_text'")
        var action: String
        
        @Guide(description: "The URL to navigate to - required for open_url")
        var url: String?
        
        @Guide(description: "CSS selector for the target element - required for click_element and input_text")
        var selector: String?
        
        @Guide(description: "The text value to input - required for input_text")
        var textValue: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: "Automating browser navigation and interactions") {
            switch arguments.action {
            case "open_url":
                guard let url = arguments.url else {
                    return "ERROR: url is required for open_url action."
                }
                return try await BrowserManager.shared.navigate(to: url)
                
            case "scrape_page":
                return try await BrowserManager.shared.scrapePage()
                
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
                
            default:
                return "ERROR: Unknown action '\(arguments.action)'. Supported: open_url, scrape_page, click_element, input_text"
            }
        }
    }
}
