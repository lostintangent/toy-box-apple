import AppKit
import CryptoKit
import Observation
import WebKit

enum ArtifactWebPolicy {
    static let htmlPermissions = [
        "allow-downloads", "allow-forms", "allow-modals", "allow-popups",
        "allow-scripts", "allow-top-navigation-by-user-activation",
    ]

    static func document(_ content: String, directory: URL) -> String {
        let base = "<base data-toybox-file-base href=\"\(attribute(directory.absoluteString))\">"
        if let head = content.range(of: #"<head(?:\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            return String(content[..<head.upperBound]) + base + content[head.upperBound...]
        } else if let html = content.range(of: #"<html(?:\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            return String(content[..<html.upperBound]) + "<head>\(base)</head>" + content[html.upperBound...]
        } else {
            return "<head>\(base)</head>" + content
        }
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
    case invalidServer, missingRules, blockedNavigation, browserUnavailable, rootDocumentUnavailable, rootNavigationUnavailable
    case invalidReadingState

    var errorDescription: String? {
        switch self {
        case .invalidServer: "The artifact's server address is unavailable."
        case .missingRules: "The artifact's network isolation could not be installed."
        case .blockedNavigation: "This document tried to open an unsupported address."
        case .browserUnavailable: "The link could not be opened in your default browser."
        case .rootDocumentUnavailable: "The document's sandboxed address could not be created."
        case .rootNavigationUnavailable: "This document cannot replace its sandboxed page. Forms that navigate and other page navigation are not supported in the artifact viewer."
        case .invalidReadingState: "The document's reading position could not be saved."
        }
    }
}

@MainActor
struct ArtifactWebReadingState {
    let document: URL
    let position: Task<CGPoint, any Error>
}

@MainActor
private final class ArtifactRootDocument: NSObject, WKURLSchemeHandler {
    static let scheme = "toybox-artifact"
    private(set) var url: URL?
    private var data: Data?

    func prepare(_ html: String, identity: URL) throws -> URL {
        let digest = SHA256.hash(data: Data((identity.absoluteString + "\n" + html).utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: "\(Self.scheme)://document/\(digest)") else {
            throw ArtifactWebError.rootDocumentUnavailable
        }
        self.url = url
        data = Data(html.utf8)
        return url
    }

    func contains(_ candidate: URL) -> Bool {
        guard var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else { return false }
        components.fragment = nil
        return url != nil && components.url == url
    }

    func clear() {
        url = nil
        data = nil
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let candidate = urlSchemeTask.request.url, contains(candidate), let data,
              urlSchemeTask.request.httpMethod == "GET" else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let headers = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": "sandbox " + ArtifactWebPolicy.htmlPermissions.joined(separator: " "),
            "Referrer-Policy": "no-referrer",
        ]
        guard let response = HTTPURLResponse(url: candidate, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            urlSchemeTask.didFailWithError(URLError(.badServerResponse))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

@MainActor @Observable
final class ArtifactWebContent: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let readingWorld = WKContentWorld.world(name: "ToyBoxArtifactReadingState")
    let webView: WKWebView
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private let openURL: (URL) -> Bool
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var resource: URL?
    @ObservationIgnored private var installedRules: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let rootDocument: ArtifactRootDocument
    @ObservationIgnored private var pendingPosition: CGPoint?

    init(openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let rootDocument = ArtifactRootDocument()
        configuration.setURLSchemeHandler(rootDocument, forURLScheme: ArtifactRootDocument.scheme)
        self.rootDocument = rootDocument
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.openURL = openURL
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    var readingState: ArtifactWebReadingState? {
        guard !isLoading, let url = rootDocument.url, let current = webView.url,
              rootDocument.contains(current) else { return nil }
        let position = Task { @MainActor [webView] in
            let result = try await webView.evaluateJavaScript("({x:window.scrollX,y:window.scrollY})",
                                                            in: nil, contentWorld: Self.readingWorld)
            guard let values = result as? [String: Double], let x = values["x"], let y = values["y"],
                  x.isFinite, y.isFinite else { throw ArtifactWebError.invalidReadingState }
            return CGPoint(x: x, y: y)
        }
        return ArtifactWebReadingState(document: url, position: position)
    }

    func load(_ content: String, directory: URL, server: URL, resource: URL? = nil,
              state: ArtifactWebReadingState? = nil) async {
        let token = UUID()
        generation = token
        error = nil
        isLoading = true
        pendingPosition = nil
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
            let html = ArtifactWebPolicy.document(content, directory: directory)
            let url = try rootDocument.prepare(html, identity: resource ?? directory)
            if let state, state.document == url {
                let position = try await state.position.value
                guard generation == token else { return }
                try Task.checkCancellation()
                pendingPosition = position
            }
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
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
        rootDocument.clear()
        pendingPosition = nil
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let position = pendingPosition else {
            isLoading = false
            return
        }
        pendingPosition = nil
        let token = generation
        Task { @MainActor [weak self] in
            guard let self, generation == token else { return }
            do {
                _ = try await webView.callAsyncJavaScript("window.scrollTo(x,y);",
                                                         arguments: ["x": position.x, "y": position.y],
                                                         in: nil, contentWorld: Self.readingWorld)
                guard generation == token else { return }
                isLoading = false
            } catch {
                guard generation == token else { return }
                record(error)
            }
        }
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
        guard !blockFormNavigation(navigationAction) else {
            decisionHandler(.cancel)
            return
        }
        guard let url = navigationAction.request.url else {
            error = ArtifactWebError.blockedNavigation.localizedDescription
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if navigationAction.targetFrame?.isMainFrame == true {
            if rootDocument.contains(url) {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType != .linkActivated || !["http", "https"].contains(scheme) {
                error = ArtifactWebError.rootNavigationUnavailable.localizedDescription
                decisionHandler(.cancel)
                return
            }
        }
        guard ["http", "https", "about", "data", "blob"].contains(scheme) else {
            error = ArtifactWebError.blockedNavigation.localizedDescription
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(scheme) {
            if let fragment = url.fragment, isSameDocument(url) {
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
        guard !blockFormNavigation(navigationAction) else { return nil }
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

    private func blockFormNavigation(_ action: WKNavigationAction) -> Bool {
        guard action.navigationType == .formSubmitted || action.navigationType == .formResubmitted else { return false }
        error = ArtifactWebError.rootNavigationUnavailable.localizedDescription
        return true
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
