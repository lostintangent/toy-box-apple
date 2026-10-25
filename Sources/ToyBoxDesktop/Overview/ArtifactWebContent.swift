import AppKit
import CryptoKit
import Observation
import WebKit

enum ArtifactWebPolicy {
    static let htmlPermissions = [
        "allow-downloads", "allow-forms", "allow-modals", "allow-popups",
        "allow-scripts", "allow-top-navigation-by-user-activation",
    ]

    static func document(_ content: String, directory: URL, kind: ArtifactContentKind) -> String {
        let svgStyle = kind == .svg
            ? "<style>html,body{width:100%;height:100%;margin:0;background:transparent;overflow:hidden}body{display:grid;place-items:center}svg{display:block;width:auto;height:auto;max-width:100%;max-height:100%}</style>"
            : ""
        let base = "<base data-toybox-file-base href=\"\(attribute(directory.absoluteString))\">" + svgStyle
        let prepared: String
        if let head = content.range(of: #"<head(?:\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            prepared = String(content[..<head.upperBound]) + base + content[head.upperBound...]
        } else if let html = content.range(of: #"<html(?:\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            prepared = String(content[..<html.upperBound]) + "<head>\(base)</head>" + content[html.upperBound...]
        } else {
            prepared = "<head>\(base)</head>" + content
        }
        let permissions = kind == .html ? htmlPermissions.joined(separator: " ") : ""
        return """
        <!doctype html><html><head><meta name="referrer" content="no-referrer">
        <style>html,body,iframe{width:100%;height:100%;margin:0;border:0}iframe{display:block}</style>
        </head><body><iframe title="Artifact" sandbox="\(permissions)" referrerpolicy="no-referrer" \
        srcdoc="\(attribute(prepared))"></iframe></body></html>
        """
    }

    static func blockingRules(server: URL) throws -> String {
        guard var origin = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            throw ArtifactWebError.invalidServer
        }
        let prefix = origin.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        origin.path = ""
        origin.query = nil
        origin.fragment = nil
        guard let address = origin.url?.absoluteString else { throw ArtifactWebError.invalidServer }
        let escapedOrigin = NSRegularExpression.escapedPattern(for: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let filePath = (prefix.isEmpty ? "" : "/\(prefix)") + "/api/serve/"
        let files = escapedOrigin + NSRegularExpression.escapedPattern(for: filePath)
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": "^\(escapedOrigin)/"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https?://[^/]+/.*api/v1"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "^wss?://[^/]+/.*api/v1"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "^\(files)"], "action": ["type": "ignore-previous-rules"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        guard let encoded = String(data: data, encoding: .utf8) else { throw ArtifactWebError.invalidServer }
        return encoded
    }

    private static func attribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum ArtifactWebError: LocalizedError {
    case invalidServer, missingRules, blockedNavigation, browserUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidServer: "The artifact's server address is unavailable."
        case .missingRules: "The artifact's network isolation could not be installed."
        case .blockedNavigation: "This document tried to open an unsupported address."
        case .browserUnavailable: "The link could not be opened in your default browser."
        }
    }
}

@MainActor @Observable
final class ArtifactWebContent: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private let openURL: (URL) -> Bool
    @ObservationIgnored private let kind: ArtifactContentKind
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var resource: URL?
    @ObservationIgnored private var installedRules: String?
    @ObservationIgnored private var generation = UUID()

    init(kind: ArtifactContentKind, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = kind == .html
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.openURL = openURL
        self.kind = kind
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load(_ content: String, directory: URL, server: URL, resource: URL? = nil) async {
        let token = UUID()
        generation = token
        error = nil
        isLoading = true
        self.directory = directory
        self.resource = resource
        do {
            let rules = try ArtifactWebPolicy.blockingRules(server: server)
            let digest = SHA256.hash(data: Data(rules.utf8)).map { String(format: "%02x", $0) }.joined()
            guard let compiled = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "artifact-\(digest)", encodedContentRuleList: rules
            ) else { throw ArtifactWebError.missingRules }
            guard generation == token else { return }
            try Task.checkCancellation()
            if installedRules != digest {
                webView.configuration.userContentController.add(compiled)
                installedRules = digest
            }
            webView.loadHTMLString(ArtifactWebPolicy.document(content, directory: directory, kind: kind), baseURL: nil)
        } catch is CancellationError {
            if generation == token { isLoading = false }
        } catch {
            guard generation == token else { return }
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func stop() {
        generation = UUID()
        webView.stopLoading()
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        record(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        record(error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            error = ArtifactWebError.blockedNavigation.localizedDescription
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "about", "data", "blob"].contains(scheme) else {
            error = ArtifactWebError.blockedNavigation.localizedDescription
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(scheme) {
            if kind == .html, let fragment = url.fragment, isSameDocument(url) {
                decisionHandler(.cancel)
                Task { @MainActor [weak self] in
                    do {
                        _ = try await webView.callAsyncJavaScript("""
                            if (!fragment) { window.scrollTo(0, 0); }
                            else {
                                const target = document.getElementById(fragment) || document.getElementsByName(fragment)[0];
                                if (target) target.scrollIntoView();
                            }
                            """, arguments: ["fragment": fragment], in: navigationAction.sourceFrame, contentWorld: .page)
                    } catch {
                        self?.error = error.localizedDescription
                    }
                }
                return
            }
            openInBrowser(url)
            decisionHandler(.cancel)
        } else if url.scheme == "about" || navigationAction.targetFrame?.isMainFrame == false
                    || navigationAction.targetFrame == nil {
            decisionHandler(.allow)
        } else {
            error = ArtifactWebError.blockedNavigation.localizedDescription
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            openInBrowser(url)
        } else {
            error = ArtifactWebError.blockedNavigation.localizedDescription
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let input = NSTextField(string: defaultText ?? "")
        input.frame.size = CGSize(width: 320, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }

    private func present(_ alert: NSAlert,
                         completion: @escaping @MainActor @Sendable (NSApplication.ModalResponse) -> Void) {
        guard let window = webView.window else {
            error = "This document tried to show a dialog before its viewer was ready."
            completion(.abort)
            return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }

    private func openInBrowser(_ url: URL) {
        if !openURL(url) { error = ArtifactWebError.browserUnavailable.localizedDescription }
    }

    private func isSameDocument(_ url: URL) -> Bool {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        parts.fragment = nil
        return parts.url == directory || parts.url == resource
    }

    private func record(_ error: any Error) {
        let native = error as NSError
        guard native.domain != NSURLErrorDomain || native.code != NSURLErrorCancelled else { return }
        self.error = error.localizedDescription
        isLoading = false
    }
}
