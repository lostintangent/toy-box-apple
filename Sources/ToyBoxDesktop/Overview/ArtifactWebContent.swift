import AppKit
import ToyBoxUI
import WebKit

typealias ArtifactWebContent = ArtifactWebRenderer

extension ArtifactWebRenderer {
    convenience init(openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.init(presentation: MacArtifactWebPresentation(openURL: openURL))
    }
}

@MainActor
private final class MacArtifactWebPresentation: ArtifactWebPresenting {
    let openURL: (URL) -> Bool

    init(openURL: @escaping (URL) -> Bool) { self.openURL = openURL }

    func openInBrowser(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        completion(openURL(url))
    }

    func showAlert(_ message: String, for webView: WKWebView,
                   completion: @escaping @MainActor @Sendable () -> Void) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        return present(alert, for: webView) { _ in completion() }
    }

    func showConfirmation(_ message: String, for webView: WKWebView,
                          completion: @escaping @MainActor @Sendable (Bool) -> Void) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return present(alert, for: webView) { completion($0 == .alertFirstButtonReturn) }
    }

    func showPrompt(_ prompt: String, defaultText: String?, for webView: WKWebView,
                    completion: @escaping @MainActor @Sendable (String?) -> Void) -> Bool {
        let alert = NSAlert()
        alert.messageText = prompt
        let input = NSTextField(string: defaultText ?? "")
        input.frame.size = CGSize(width: 320, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return present(alert, for: webView) { completion($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }

    private func present(_ alert: NSAlert, for webView: WKWebView,
                         completion: @escaping @MainActor @Sendable (NSApplication.ModalResponse) -> Void) -> Bool {
        guard let window = webView.window else { return false }
        alert.beginSheetModal(for: window, completionHandler: completion)
        return true
    }
}
