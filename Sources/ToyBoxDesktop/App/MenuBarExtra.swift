import AppKit
import Observation
import SwiftUI

/// Whether the menu bar extra is in the menu bar. When Active shows it as soon as anything is
/// active, keeps it for a while after the last activity ends, and never removes it while a menu
/// is open, so it can't vanish under the pointer.
@MainActor @Observable
final class MenuBarPresence {
    private(set) var isInserted = false
    private(set) var presentationRequest: UUID?
    @ObservationIgnored var visibility: MenuBarVisibility = .whenActive {
        didSet { if visibility != oldValue { settle() } }
    }
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var lingers = false
    @ObservationIgnored private var isMenuOpen = false
    @ObservationIgnored private var isPopoverOpen = false
    /// The countdown after activity ends, awaitable so tests needn't race it.
    @ObservationIgnored private(set) var linger: Task<Void, Never>?
    @ObservationIgnored private var observers: [NotificationCenter.ObservationToken] = []
    @ObservationIgnored private let lingerDuration: Duration

    init(linger: Duration = MenuBarVisibility.linger, center: NotificationCenter = .default) {
        lingerDuration = linger
        observers = [
            center.addObserver(of: NSMenu.self, for: .didBeginTracking) { [weak self] _ in self?.menuTracking(true) },
            center.addObserver(of: NSMenu.self, for: .didEndTracking) { [weak self] _ in self?.menuTracking(false) },
        ]
    }

    func update(isActive: Bool) {
        guard isActive != self.isActive else { return }
        self.isActive = isActive
        linger?.cancel()
        lingers = !isActive && isInserted
        if lingers {
            linger = Task { [weak self, lingerDuration] in
                try? await Task.sleep(for: lingerDuration)
                guard !Task.isCancelled, let self else { return }
                self.lingers = false
                self.settle()
            }
        }
        settle()
    }

    func menuTracking(_ open: Bool) {
        isMenuOpen = open
        settle()
    }

    func popoverVisibilityChanged(_ visible: Bool) {
        if isPopoverOpen && !visible { presentationRequest = nil }
        isPopoverOpen = visible
        settle()
    }

    func requestPresentation() {
        guard !isPopoverOpen else { return }
        presentationRequest = UUID()
        settle()
    }

    func presentationFailed(id: UUID) {
        guard presentationRequest == id else { return }
        presentationRequest = nil
        settle()
    }

    private func settle() {
        let inserted = switch visibility {
        case .always: true
        case .never: false
        case .whenActive: isActive || lingers || (isInserted && (isMenuOpen || isPopoverOpen))
        }
        let next = inserted || presentationRequest != nil
        if next != isInserted { isInserted = next }
    }
}

/// The status item: one template symbol, never animated in place and never colored.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let status = model.menuBarStatus
        Label {
            Text(MenuBarAccessibility.title)
        } icon: {
            // The status item takes its accessibility title from the symbol's label.
            Image(systemName: status.symbol)
                .accessibilityLabel(MenuBarAccessibility.title)
        }
        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        .task(id: status.accessibilityValue) { await MenuBarAccessibility.apply(status.accessibilityValue) }
        .task(id: model.menuBar.presentationRequest) {
            guard let id = model.menuBar.presentationRequest else { return }
            do {
                try await MenuBarAccessibility.presentInbox()
            } catch is CancellationError {
                model.menuBar.presentationFailed(id: id)
            } catch {
                model.menuBar.presentationFailed(id: id)
                NSApp.presentError(error)
            }
        }
    }
}

/// SwiftUI doesn't carry a menu bar extra label's accessibility value to its status item, so
/// VoiceOver would hear the app's name and nothing of the team. The value goes on the item's
/// button instead.
@MainActor
enum MenuBarAccessibility {
    static let title = "Toy Box"

    static func presentInbox() async throws {
        for _ in 0..<20 {
            try Task.checkCancellation()
            if let button = statusButtons().first {
                button.performClick(nil)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw InboxError.unavailable
    }

    private enum InboxError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Toy Box couldn't open the inbox. Try its menu bar icon again." }
    }

    static func apply(_ value: String) async {
        // The scene inserts the button just after the label first renders.
        for _ in 0..<20 {
            let buttons = statusButtons()
            if !buttons.isEmpty {
                for button in buttons where button.accessibilityValue() as? String != value {
                    button.setAccessibilityValue(value)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
    }

    private static func statusButtons() -> [NSStatusBarButton] {
        func buttons(in view: NSView) -> [NSStatusBarButton] {
            if let button = view as? NSStatusBarButton { return [button] }
            return view.subviews.flatMap(buttons)
        }
        return NSApp.windows.filter { $0.level == .statusBar }.compactMap(\.contentView).flatMap(buttons)
    }
}
