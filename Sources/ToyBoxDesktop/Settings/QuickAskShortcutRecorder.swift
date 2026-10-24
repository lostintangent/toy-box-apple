import AppKit
import SwiftUI

struct QuickAskShortcutRecorder: NSViewRepresentable {
    let controller: QuickAskController

    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.target = button
        button.action = #selector(ShortcutButton.record)
        button.setAccessibilityLabel("Quick Ask keyboard shortcut")
        button.toolTip = "Record a global shortcut. Escape cancels. Delete clears it."
        return button
    }

    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.controller = controller
        button.refreshTitle()
    }

    static func dismantleNSView(_ button: ShortcutButton, coordinator: ()) {
        button.stopRecording()
    }
}

final class ShortcutButton: NSButton {
    weak var controller: QuickAskController?
    private var isRecording = false
    override var acceptsFirstResponder: Bool { true }

    @objc func record() {
        guard !isRecording else { stopRecording(); return }
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        controller?.setRecording(true)
        refreshTitle()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        controller?.setRecording(false)
        refreshTitle()
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53 {
            stopRecording()
        } else if event.keyCode == 48 {
            stopRecording()
            super.keyDown(with: event)
        } else if [51, 117].contains(event.keyCode),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            controller?.setShortcut(nil)
            stopRecording()
        } else {
            let shortcut = QuickAskShortcut(keyCode: event.keyCode, flags: event.modifierFlags)
            if let error = shortcut.validationError {
                controller?.reportInvalidShortcut(error)
            } else {
                controller?.setShortcut(shortcut)
                stopRecording()
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { super.flagsChanged(with: event); return }
        let modifiers = QuickAskShortcut(keyCode: 0, flags: event.modifierFlags).modifierLabel
        title = modifiers.isEmpty ? "Press Shortcut" : modifiers + "…"
    }

    func refreshTitle() {
        title = isRecording ? "Press Shortcut" : controller?.shortcut?.displayName ?? "Record Shortcut"
        setAccessibilityValue(isRecording ? "Recording shortcut" : controller?.shortcut?.displayName ?? "Not set")
    }
}
