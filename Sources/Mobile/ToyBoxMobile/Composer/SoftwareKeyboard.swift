import SwiftUI
import UIKit

/// UIKit has no keyboard-visibility property, only a view's keyboard layout guide. The channel screen
/// owns the one probe, so the composer, Find and the notification tip agree even while Find has
/// replaced the composer.
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
        // The view stays above the keyboard, so the probe reaches under it.
        background { SoftwareKeyboardProbe { isVisible.wrappedValue = $0 }.ignoresSafeArea() }
            .environment(\.softwareKeyboardIsVisible, isVisible.wrappedValue)
    }
}

struct SoftwareKeyboardProbe: UIViewRepresentable {
    var changed: (Bool) -> Void

    func makeUIView(context: Context) -> ProbeView { ProbeView(changed: changed) }

    func updateUIView(_ view: ProbeView, context: Context) { view.changed = changed }

    /// Reads the keyboard's layout guide on every layout, so a keyboard that was already up when the
    /// screen arrived counts from its first one.
    final class ProbeView: UIView {
        var changed: (Bool) -> Void
        private var reported: Bool?
        /// Spans the keyboard's part of the view, so the keyboard moving lays this view out.
        private let keyboard = UIView()

        init(changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            keyboard.isHidden = true
            keyboard.translatesAutoresizingMaskIntoConstraints = false
            addSubview(keyboard)
            NSLayoutConstraint.activate([
                keyboard.leadingAnchor.constraint(equalTo: leadingAnchor),
                keyboard.trailingAnchor.constraint(equalTo: trailingAnchor),
                keyboard.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                keyboard.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { return }
            let frame = convert(keyboardLayoutGuide.layoutFrame, to: window)
            let visible = SoftwareKeyboard.isVisible(frame: frame, in: window.bounds,
                                                     safeAreaBottom: window.safeAreaInsets.bottom)
            guard visible != reported else { return }
            reported = visible
            changed(visible)
        }
    }
}
