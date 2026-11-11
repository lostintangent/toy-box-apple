import ChannelKit
import Foundation

/// One viewer's keyboard in control, which turns key events into the host's key input, as the browser
/// pane does. Keys go to the host by DOM code, and only the release of a press it sent follows, so a
/// key held when control began never reaches the host. A viewer starts a fresh one whenever it takes
/// control, since releasing control lets go of every key on the host.
public struct ScreenKeyboard: Sendable {
    /// Keys down on the host, in the order they went down.
    private var pressed: [String] = []

    public init() {}

    /// A key went down, or repeated, by its DOM code, like `Screen.Input.keyCode(mac:)` returns.
    public mutating func press(_ code: String) -> [Screen.Input] {
        if !pressed.contains(code) { pressed.append(code) }
        return [.key(code, down: true)]
    }

    /// A key went up. Only a key whose press was sent is released.
    public mutating func release(_ code: String) -> [Screen.Input] {
        guard let index = pressed.firstIndex(of: code) else { return [] }
        pressed.remove(at: index)
        return [.key(code, down: false)]
    }

    /// A Mac modifier went down or up, from `flagsChanged`'s `keyCode` and `modifierFlags.rawValue`.
    /// The flags tell each side's key apart, so a key held before control began only ever releases
    /// nothing. Caps Lock toggles on the host with a press and release each time.
    public mutating func modifierChanged(mac keyCode: UInt16, flags: UInt) -> [Screen.Input] {
        guard let code = Screen.Input.keyCode(mac: keyCode) else { return [] }
        if code == "CapsLock" { return [.key(code, down: true), .key(code, down: false)] }
        guard let mask = Self.macModifierMasks[code] else { return [] }
        return flags & mask != 0 ? press(code) : release(code)
    }

    /// Types the clipboard's text, for Command-V. The host types with the modifiers it holds, so they
    /// lift around the text and press again, and a Command-C that follows still has Command.
    public func paste(_ text: String) -> [Screen.Input] {
        guard !text.isEmpty else { return [] }
        let held = pressed.filter(Self.macModifierMasks.keys.contains)
        return held.map { .key($0, down: false) } + [.text(text)] + held.map { .key($0, down: true) }
    }

    /// What the phone's software keyboard typed: text, with each line break as Return.
    public func type(_ text: String) -> [Screen.Input] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated().flatMap { index, line in
            (index == 0 ? [] : Self.tap("Enter")) + (line.isEmpty ? [] : [.text(String(line))])
        }
    }

    /// The phone's software keyboard deleted backward.
    public func deleteBackward() -> [Screen.Input] { Self.tap("Backspace") }

    private static func tap(_ code: String) -> [Screen.Input] {
        [.key(code, down: true), .key(code, down: false)]
    }

    /// Each modifier's side-specific bit in a Mac event's modifier flags, from IOKit's `IOLLEvent.h`.
    private static let macModifierMasks: [String: UInt] = [
        "ControlLeft": 0x0001, "ShiftLeft": 0x0002, "ShiftRight": 0x0004, "MetaLeft": 0x0008,
        "MetaRight": 0x0010, "AltLeft": 0x0020, "AltRight": 0x0040, "ControlRight": 0x2000,
    ]
}
