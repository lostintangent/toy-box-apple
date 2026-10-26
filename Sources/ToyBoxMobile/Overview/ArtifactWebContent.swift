import ToyBoxUI
import UIKit
import WebKit

extension ArtifactWebRenderer {
    static func phone() -> ArtifactWebRenderer {
        let renderer = ArtifactWebRenderer(presentation: PhoneArtifactWebPresentation())
        renderer.webView.allowsBackForwardNavigationGestures = false
        renderer.webView.allowsLinkPreview = false
        return renderer
    }
}

@MainActor
private final class PhoneArtifactWebPresentation: ArtifactWebPresenting {
    func openInBrowser(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        UIApplication.shared.open(url, options: [:]) { opened in
            Task { @MainActor in completion(opened) }
        }
    }

    func showAlert(_ message: String, for webView: WKWebView,
                   completion: @escaping @MainActor @Sendable () -> Void) -> Bool {
        let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion() })
        return present(alert, for: webView)
    }

    func showConfirmation(_ message: String, for webView: WKWebView,
                          completion: @escaping @MainActor @Sendable (Bool) -> Void) -> Bool {
        let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(true) })
        return present(alert, for: webView)
    }

    func showPrompt(_ prompt: String, defaultText: String?, for webView: WKWebView,
                    completion: @escaping @MainActor @Sendable (String?) -> Void) -> Bool {
        let alert = UIAlertController(title: prompt, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completion(alert?.textFields?.first?.text)
        })
        return present(alert, for: webView)
    }

    private func present(_ alert: UIAlertController, for webView: WKWebView) -> Bool {
        guard let window = webView.window else { return false }
        var responder: UIResponder? = webView
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let controller = responder as? UIViewController,
              controller.viewIfLoaded?.window === window, controller.presentedViewController == nil else { return false }
        controller.present(alert, animated: true)
        return true
    }
}
