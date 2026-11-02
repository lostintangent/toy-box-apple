import AppKit
import OSLog

@objc(ToyBoxShareViewController)
final class ShareViewController: NSViewController {
    private static let logger = Logger(subsystem: "dev.toybox.desktop.share", category: "Share")

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func beginRequest(with context: NSExtensionContext) {
        super.beginRequest(with: context)
        Task {
            var pasteboard: NSPasteboard?
            do {
                let content = try await ShareContent.load(context.inputItems)
                let board = NSPasteboard(name: .init("dev.toybox.desktop.share.\(UUID().uuidString)"))
                pasteboard = board
                let url = try ShareContent.write(content, to: board)
                let app = Bundle.main.bundleURL.deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                guard app.pathExtension == "app" else { throw ShareContent.Failure.invalidItem }
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init())
                context.completeRequest(returningItems: nil)
            } catch {
                pasteboard?.releaseGlobally()
                Self.logger.error("Could not hand off shared content: \(error.localizedDescription, privacy: .public)")
                context.cancelRequest(withError: error)
            }
        }
    }
}
