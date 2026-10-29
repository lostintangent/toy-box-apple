import SwiftUI
import UIKit

/// UIKit has no keyboard-visibility property, only frame-change notifications and the window's
/// keyboard layout guide. The channel screen owns the one observer, so the composer, Find and the
/// notification tip agree even while Find has replaced the composer.
enum SoftwareKeyboard {
    /// The home indicator's safe area isn't a keyboard, and neither is a frame off the window.
    static func isVisible(frame: CGRect, in bounds: CGRect, safeAreaBottom: CGFloat) -> Bool {
        let overlap = bounds.intersection(frame)
        return !overlap.isNull && overlap.height > safeAreaBottom + 0.5
    }
}

private struct SoftwareKeyboardVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var softwareKeyboardIsVisible: Bool {
        get { self[SoftwareKeyboardVisibleKey.self] }
        set { self[SoftwareKeyboardVisibleKey.self] = newValue }
    }
}

extension View {
    /// Tracks the keyboard from this view's window and publishes it to the subtree.
    func softwareKeyboardVisibility(_ isVisible: Binding<Bool>) -> some View {
        background { SoftwareKeyboardProbe { isVisible.wrappedValue = $0 } }
            .environment(\.softwareKeyboardIsVisible, isVisible.wrappedValue)
    }
}

struct SoftwareKeyboardProbe: UIViewRepresentable {
    var changed: (Bool) -> Void

    func makeUIView(context: Context) -> ProbeView { ProbeView(changed: changed) }

    func updateUIView(_ view: ProbeView, context: Context) { view.changed = changed }

    final class ProbeView: UIView {
        var changed: (Bool) -> Void
        private var reported: Bool?
        private var seed: Task<Void, Never>?

        init(changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardWillChangeFrame(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        // A keyboard already up when the screen arrives sent its notification earlier, so the
        // window's layout guide seeds the state. It reads after this update, so the state changes
        // outside it, and a notification that lands first wins.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            seed?.cancel()
            guard let window else { return }
            _ = window.keyboardLayoutGuide
            seed = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self, let window = self.window else { return }
                self.report(window.keyboardLayoutGuide.layoutFrame, in: window)
            }
        }

        @objc private func keyboardWillChangeFrame(_ notification: Notification) {
            guard let window,
                  let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            else { return }
            seed?.cancel()
            report(window.convert(frame, from: window.screen.coordinateSpace), in: window)
        }

        private func report(_ frame: CGRect, in window: UIWindow) {
            let visible = SoftwareKeyboard.isVisible(frame: frame, in: window.bounds,
                                                     safeAreaBottom: window.safeAreaInsets.bottom)
            guard visible != reported else { return }
            reported = visible
            changed(visible)
        }
    }
}
