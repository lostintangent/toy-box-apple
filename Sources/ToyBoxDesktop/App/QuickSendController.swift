import AppKit
import ChannelKit
import Observation
import OSLog
import SwiftUI
import ToyBoxUI

@MainActor @Observable
final class QuickSendController: NSObject, NSWindowDelegate {
    let isEnabled: Bool
    private(set) var shortcut: QuickSendShortcut?
    private(set) var error: String?
    private(set) var isPresented = false
    private(set) var presentationID = UUID()
    private(set) var isRecording = false
    private(set) var isRegistered = false
    private(set) var pendingPrefill: QuickSendPrefill?
    private(set) var replyTarget: NeedsYouRequestLink?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let hotKey: any QuickSendHotKeyRegistering
    @ObservationIgnored private var panel: QuickSendPanel?
    @ObservationIgnored private var hosting: NSHostingView<AnyView>?
    @ObservationIgnored private var content = AnyView(QuickSendPlaceholder())
    @ObservationIgnored private let validation: QuickSendValidation?
    private static let logger = Logger(subsystem: "dev.toybox.desktop", category: "QuickSend")

    init(options: LaunchOptions = .init(), defaults: UserDefaults = .standard,
         hotKey: any QuickSendHotKeyRegistering = CarbonQuickSendHotKey()) {
        isEnabled = !options.isSnapshot && options.benchmark == nil && options.resizeBenchmark == nil
        validation = options.quickSendValidation
        self.defaults = defaults
        self.hotKey = hotKey
        super.init()
        do {
            if let data = defaults.data(forKey: QuickSendShortcut.preferenceKey) {
                shortcut = try JSONDecoder().decode(QuickSendShortcut?.self, from: data)
            } else {
                shortcut = .defaultValue
            }
            if let validationError = shortcut?.validationError {
                error = "The saved shortcut is invalid. \(validationError)"
                shortcut = nil
            } else {
                registerShortcut()
            }
        } catch {
            self.error = "The saved Quick Send shortcut couldn't be read. Record it again."
        }
    }

    func setShortcut(_ value: QuickSendShortcut?) {
        guard isEnabled else { return }
        if let validationError = value?.validationError {
            error = validationError
            return
        }
        do {
            let data = try JSONEncoder().encode(value)
            try hotKey.replace(with: value) { [weak self] in self?.toggle() }
            isRegistered = value != nil
            shortcut = value
            defaults.set(data, forKey: QuickSendShortcut.preferenceKey)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setRecording(_ recording: Bool) {
        guard isRecording != recording else { return }
        if recording {
            do {
                if isRegistered {
                    try hotKey.replace(with: nil) {}
                    isRegistered = false
                }
                isRecording = true
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        } else {
            isRecording = false
            registerShortcut(clearingError: false)
        }
    }

    func reportInvalidShortcut(_ message: String) { error = message }

    private func registerShortcut(clearingError: Bool = true) {
        guard isEnabled, !isRegistered, let shortcut else { return }
        do {
            try hotKey.replace(with: shortcut) { [weak self] in self?.toggle() }
            isRegistered = true
            if clearingError { error = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setContent(_ view: some View) {
        content = AnyView(view)
        hosting?.rootView = hostedContent()
    }

    func toggle() {
        if isPresented { dismiss() }
        else { present() }
    }

    func present() {
        replyTarget = nil
        show()
    }

    func present(replyTo request: NeedsYouRequestLink) {
        replyTarget = request
        show()
    }

    func leaveReply() { replyTarget = nil }

    private func show() {
        guard isEnabled else { return }
        if panel == nil {
            let panel = QuickSendPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220),
                                      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                      backing: .buffered, defer: false)
            panel.delegate = self
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.canHide = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.animationBehavior = .utilityWindow
            panel.isMovableByWindowBackground = true
            panel.title = "Quick Send"
            panel.setAccessibilityLabel("Quick Send")
            panel.onCancel = { [weak self] in self?.dismiss() }
            let hosting = NSHostingView(rootView: hostedContent())
            hosting.sizingOptions = [.intrinsicContentSize]
            panel.contentView = hosting
            self.hosting = hosting
            self.panel = panel
        }
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen {
            panel.setFrame(Self.frame(size: panel.frame.size, in: screen.visibleFrame), display: false)
        }
        presentationID = UUID()
        isPresented = true
        panel.makeKeyAndOrderFront(nil)
        if validation != nil {
            tracePanel("presented")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tracePanel("settled") }
        }
    }

    func present(prefill: QuickSendPrefill) {
        if let pending = pendingPrefill {
            pendingPrefill = pending.appending(prefill)
        } else {
            pendingPrefill = prefill
        }
        present()
    }

    func consumePrefill(id: UUID) {
        if pendingPrefill?.id == id { pendingPrefill = nil }
    }

    private func tracePanel(_ phase: String) {
        guard let panel else { return }
        Self.logger.notice("""
            Quick Send \(phase, privacy: .public): visible=\(panel.isVisible), key=\(panel.isKeyWindow), \
            alpha=\(panel.alphaValue), frame=\(String(describing: panel.frame), privacy: .public), \
            role=\(panel.accessibilityRole()?.rawValue ?? "nil", privacy: .public), \
            subrole=\(panel.accessibilitySubrole()?.rawValue ?? "nil", privacy: .public)
            """)
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        panel?.orderOut(nil)
        if validation != nil { Self.logger.notice("Dismissed Quick Send") }
    }

    func windowDidResignKey(_ notification: Notification) {
        if validation != nil { Self.logger.notice("Quick Send resigned key") }
        guard validation != .hold else { return }
        // Attachment sheets and popovers belong to the panel, not to a click away.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, !panel.isKeyWindow, panel.attachedSheet == nil else { return }
            var parent = NSApp.keyWindow
            while let window = parent {
                if window == panel { return }
                parent = window.parent
            }
            if self.validation != nil { Self.logger.notice("Dismissing Quick Send after resign key") }
            self.dismiss()
        }
    }

    static func frame(size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let bounds = visibleFrame.insetBy(dx: 24, dy: 24)
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let top = visibleFrame.maxY - visibleFrame.height * 0.22
        return CGRect(x: bounds.midX - width / 2,
                      y: min(max(top - height, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }

    private func hostedContent() -> AnyView {
        AnyView(QuickSendAppearance(content: content)
            .frame(width: 560)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                guard let panel = self?.panel, size.height.isFinite, size.height > 0 else { return }
                let top = panel.frame.maxY
                let available = panel.screen?.visibleFrame.insetBy(dx: 24, dy: 24)
                let height = min(size.height, 420, available?.height ?? 420)
                panel.setContentSize(NSSize(width: size.width, height: height))
                let bottom = max(top - panel.frame.height, available?.minY ?? -CGFloat.infinity)
                panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: bottom))
            })
    }
}

struct QuickSendMenuButton: View {
    let controller: QuickSendController

    var body: some View {
        Button("Quick Send…") { controller.present() }
            .keyboardShortcut(controller.isRegistered && !controller.isRecording
                              ? controller.shortcut?.keyboardShortcut : nil)
            .disabled(!controller.isEnabled || controller.isRecording)
    }
}

final class QuickSendPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .floatingWindow }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == "w",
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct QuickSendAppearance: View {
    let content: AnyView
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage("textScale") private var textScale = 1.0

    var body: some View {
        content
            .environment(\.channelTextScale, textScale)
            .preferredColorScheme(appearance.colorScheme)
    }
}

private struct QuickSendPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Send").font(.headline)
            Text("Send a message to your team from anywhere.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}
