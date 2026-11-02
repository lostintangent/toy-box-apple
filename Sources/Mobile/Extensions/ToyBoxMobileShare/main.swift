import Intents
import OSLog
import SwiftUI
import ToyBoxMobileIntegrations
import UIKit

/// The share sheet's window. It posts by itself, since an iOS share extension can't open its app.
@objc(ToyBoxMobileShareViewController)
final class ShareViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private var session: MobileShareSession?

    override func viewDidLoad() {
        super.viewDidLoad()
        let history: MobileShareHistory?
        do { history = try MobileShareHistory() } catch {
            Logger(subsystem: "dev.toybox.mobile.share", category: "Share")
                .error("Could not open the share history: \(error.localizedDescription)")
            history = nil
        }
        let session = MobileShareSession(history: history, intent: extensionContext?.intent as? INSendMessageIntent)
        self.session = session
        let host = UIHostingController(rootView: ShareSheet(
            session: session,
            close: { [weak self] in self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) },
            finish: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            guardDismissal: { [weak self] in self?.isModalInPresentation = $0 }
        ))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let title = items.lazy.compactMap { ($0.attributedContentText ?? $0.attributedTitle)?.string }.first
        Task { await session.start(providers, title: title) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
    }

    /// A swipe down while the note has text asks first. One while sending does nothing.
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        guard let session, session.phase != .sending, session.phase != .sent else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Discard Note", style: .destructive) { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        sheet.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }
}
