import AppKit
import ToyBoxClient
import ToyBoxKit
import SwiftUI
import ToyBoxUI

/// One screen in a Screens window, live while any of the window shows. Going back, or a
/// miniaturized, hidden or fully covered window, closes its socket, so the host stops capturing for it.
/// Take Control in the toolbar hands the window's mouse, scroll and keys to the host.
struct ScreenViewer: View {
    @ViewState private var connection: ScreenConnection
    @ViewState private var isVisible = false

    init(api: ChannelAPI, screenID: String) {
        _connection = ViewState(wrappedValue: ScreenConnection(api: api, screenID: screenID))
    }

    var body: some View {
        ScreenView(connection: connection, isActive: isVisible)
            .overlay {
                // A fresh surface for each take, so nothing pressed carries over.
                if connection.state.hasControl { Control(connection: connection) }
            }
            .navigationTitle(connection.state.title ?? "Screen")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ScreenView.ControlToggle(connection: connection) }
            }
            .background(Occlusion(isVisible: $isVisible))
    }

    private struct Control: NSViewRepresentable {
        let connection: ScreenConnection

        func makeNSView(context: Context) -> ScreenControlSurface {
            ScreenControlSurface(picture: { connection.picture }, send: connection.send, release: connection.releaseControl)
        }
        func updateNSView(_ surface: ScreenControlSurface, context: Context) {}
        static func dismantleNSView(_ surface: ScreenControlSurface, coordinator: ()) { surface.stop() }
    }

    private struct Occlusion: NSViewRepresentable {
        @Binding var isVisible: Bool

        func makeNSView(context: Context) -> Observer { Observer() }
        func updateNSView(_ view: Observer, context: Context) { view.report = { isVisible = $0 } }

        final class Observer: NSView {
            var report: (Bool) -> Void = { _ in }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                NotificationCenter.default.removeObserver(self)
                guard let window else { return }
                NotificationCenter.default.addObserver(self, selector: #selector(reportVisibility),
                                                       name: NSWindow.didChangeOcclusionStateNotification,
                                                       object: window)
                // Outside the SwiftUI update that moved the view.
                DispatchQueue.main.async { [weak self] in self?.reportVisibility() }
            }

            @objc private func reportVisibility() { report(window?.occlusionState.contains(.visible) == true) }
        }
    }
}

/// The viewer's space while it controls the host. The mouse hovers, presses its three buttons and drags
/// where it is on the fitted picture, and scrolls there, sending nothing off the picture. While it has
/// keyboard focus, every key goes to the host by its code, Command shortcuts too, and Command-V sends
/// the clipboard as text. The window losing key status releases control.
final class ScreenControlSurface: NSView {
    private let picture: () -> Screen.Picture
    private let send: ([Screen.Input]) -> Void
    private let release: () -> Void
    private let pasteboard: NSPasteboard
    private var pointer = ScreenPointer()
    private var keyboard = ScreenKeyboard()
    private var keys: Any?

    init(picture: @escaping () -> Screen.Picture, send: @escaping ([Screen.Input]) -> Void,
         release: @escaping () -> Void, pasteboard: NSPasteboard = .general) {
        (self.picture, self.send, self.release, self.pasteboard) = (picture, send, release, pasteboard)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(resignKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
        // Command shortcuts never reach a view's keyDown, and the menu bar would answer them.
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) == true } ? nil : event
        }
        // Outside the SwiftUI update that added the view.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            if !window.isKeyWindow { self.resignKey() }
        }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    // The mouse

    override func mouseDown(with event: NSEvent) { press(.primary, event) }
    override func rightMouseDown(with event: NSEvent) { press(.secondary, event) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { press(.middle, event) } }
    override func mouseUp(with event: NSEvent) { lift(.primary, event) }
    override func rightMouseUp(with event: NSEvent) { lift(.secondary, event) }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { lift(.middle, event) } }
    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseDragged(with event: NSEvent) { hover(event) }
    override func rightMouseDragged(with event: NSEvent) { hover(event) }
    override func otherMouseDragged(with event: NSEvent) { hover(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let position = position(of: event), event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return }
        // Lines from a wheel scroll the host as the browser does, in DOM pixels.
        let pixels = event.hasPreciseScrollingDeltas ? 1.0 : 16.0
        send([.scroll(at: position, dx: -event.scrollingDeltaX * pixels, dy: -event.scrollingDeltaY * pixels)])
    }

    private func press(_ button: Screen.Input.Button, _ event: NSEvent) {
        window?.makeFirstResponder(self)
        send(pointer.press(button, at: position(of: event)))
    }

    private func lift(_ button: Screen.Input.Button, _ event: NSEvent) {
        send(pointer.release(button, at: position(of: event)))
    }

    private func hover(_ event: NSEvent) { send(pointer.move(to: position(of: event))) }

    private func position(of event: NSEvent) -> CGPoint? {
        picture().position(of: convert(event.locationInWindow, from: nil), fittedIn: bounds)
    }

    // The keyboard

    /// Sends a key in this window to the host while the screen has keyboard focus, and reports whether it did.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.firstResponder === self else { return false }
        switch event.type {
        case .keyDown where event.keyCode == 9
            && event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command:
            send(keyboard.paste(pasteboard.string(forType: .string) ?? ""))
        case .keyDown:
            if let code = Screen.Input.keyCode(mac: event.keyCode) { send(keyboard.press(code)) }
        case .keyUp:
            if let code = Screen.Input.keyCode(mac: event.keyCode) { send(keyboard.release(code)) }
        case .flagsChanged:
            send(keyboard.modifierChanged(mac: event.keyCode, flags: event.modifierFlags.rawValue))
        default:
            return false
        }
        return true
    }

    @objc private func resignKey() { release() }
}
