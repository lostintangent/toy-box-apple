import CoreGraphics
import Foundation

extension Screen {
    /// One action on the host while a viewer has control. Positions are fractions of the frame from
    /// its top left, and keys are named by their DOM `KeyboardEvent.code`.
    public enum Input: Equatable, Sendable {
        /// A move drags with whatever button is down, so only a press and release name theirs.
        case pointer(Phase, at: CGPoint, button: Button = .primary)
        /// Pixels in a DOM wheel's sense, so a positive `dy` scrolls down, toward the end.
        case scroll(at: CGPoint, dx: Double, dy: Double)
        case key(String, down: Bool)
        case text(String)

        public enum Phase: String, Sendable { case move, down, up }

        /// Numbered like a DOM mouse button, which differs from `NSEvent.buttonNumber`.
        public enum Button: Int, Sendable { case primary, middle, secondary }

        /// The DOM code of a Mac key, by its `NSEvent.keyCode`, or nil for a key the host can't press.
        public static func keyCode(mac: UInt16) -> String? { macKeys[mac] }

        /// The DOM code of a USB keyboard usage, by `UIKey.keyCode.rawValue`, or nil for a key the host
        /// can't press.
        public static func keyCode(hidUsage: Int) -> String? { hidKeys[hidUsage] }

        /// Actions in the server's sizes: at most 64 to a message, and text in pieces of at most 4,096
        /// UTF-16 units that keep each character whole. An action the server would refuse, like empty
        /// text or a code it can't name, is dropped, since a refusal would release control.
        package static func batches(_ actions: [Self]) -> [[Self]] {
            let actions = actions.flatMap { action -> [Self] in
                switch action {
                case .key(let code, _): (1...32).contains(code.utf16.count) ? [action] : []
                case .text(let text): pieces(of: text).map(Self.text)
                case .pointer, .scroll: [action]
                }
            }
            return stride(from: 0, to: actions.count, by: maximumBatch).map {
                Array(actions[$0..<min($0 + maximumBatch, actions.count)])
            }
        }

        static let maximumBatch = 64
        static let maximumText = 4096

        private static func pieces(of text: String) -> [String] {
            var pieces: [String] = [], piece = ""
            for character in text {
                if piece.utf16.count + character.utf16.count > maximumText {
                    if !piece.isEmpty { pieces.append(piece) }
                    piece = ""
                }
                if character.utf16.count > maximumText {
                    // A character too long to send whole, which only a pathological string holds.
                    for scalar in character.unicodeScalars {
                        if piece.utf16.count + scalar.utf16.count > maximumText { pieces.append(piece); piece = "" }
                        piece.unicodeScalars.append(scalar)
                    }
                } else {
                    piece.append(character)
                }
            }
            if !piece.isEmpty { pieces.append(piece) }
            return pieces
        }
    }

    /// What a viewer asks of the server in control. Acks and resizes keep their own messages.
    package enum Request: Encodable, Equatable, Sendable {
        case takeControl, releaseControl
        case input([Input])

        private enum CodingKeys: String, CodingKey { case type, actions }

        package func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .takeControl: try container.encode("take-control", forKey: .type)
            case .releaseControl: try container.encode("release-control", forKey: .type)
            case .input(let actions):
                try container.encode("input", forKey: .type)
                try container.encode(actions, forKey: .actions)
            }
        }
    }
}

extension Screen.Input: Encodable {
    private enum CodingKeys: String, CodingKey { case type, x, y, phase, button, dx, dy, code, down, text }

    /// Clamps what the host would refuse: positions to within the frame, short of its far edges, and
    /// scrolls to 10,000 pixels.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func encode(_ position: CGPoint) throws {
            let clamped = { (value: CGFloat) in value.isFinite ? min(max(Double(value), 0), 1.0.nextDown) : 0 }
            try container.encode(clamped(position.x), forKey: .x)
            try container.encode(clamped(position.y), forKey: .y)
        }
        let pixels = { (value: Double) in value.isFinite ? min(max(value, -10_000), 10_000) : 0 }
        switch self {
        case let .pointer(phase, position, button):
            try container.encode("pointer", forKey: .type)
            try encode(position)
            try container.encode(phase.rawValue, forKey: .phase)
            if phase != .move { try container.encode(button.rawValue, forKey: .button) }
        case let .scroll(position, dx, dy):
            try container.encode("scroll", forKey: .type)
            try encode(position)
            try container.encode(pixels(dx), forKey: .dx)
            try container.encode(pixels(dy), forKey: .dy)
        case let .key(code, down):
            try container.encode("key", forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encode(down, forKey: .down)
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }
}

/// The host's keys, by Mac virtual key code, the inverse of the helper's table.
private let macKeys: [UInt16: String] = [
    0: "KeyA", 1: "KeyS", 2: "KeyD", 3: "KeyF", 4: "KeyH", 5: "KeyG", 6: "KeyZ", 7: "KeyX", 8: "KeyC",
    9: "KeyV", 11: "KeyB", 12: "KeyQ", 13: "KeyW", 14: "KeyE", 15: "KeyR", 16: "KeyY", 17: "KeyT",
    18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 22: "Digit6", 23: "Digit5", 24: "Equal",
    25: "Digit9", 26: "Digit7", 27: "Minus", 28: "Digit8", 29: "Digit0", 30: "BracketRight", 31: "KeyO",
    32: "KeyU", 33: "BracketLeft", 34: "KeyI", 35: "KeyP", 36: "Enter", 37: "KeyL", 38: "KeyJ",
    39: "Quote", 40: "KeyK", 41: "Semicolon", 42: "Backslash", 43: "Comma", 44: "Slash", 45: "KeyN",
    46: "KeyM", 47: "Period", 48: "Tab", 49: "Space", 50: "Backquote", 51: "Backspace", 53: "Escape",
    54: "MetaRight", 55: "MetaLeft", 56: "ShiftLeft", 57: "CapsLock", 58: "AltLeft", 59: "ControlLeft",
    60: "ShiftRight", 61: "AltRight", 62: "ControlRight", 65: "NumpadDecimal", 67: "NumpadMultiply",
    69: "NumpadAdd", 71: "NumLock", 75: "NumpadDivide", 76: "NumpadEnter", 78: "NumpadSubtract",
    81: "NumpadEqual", 82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3", 86: "Numpad4",
    87: "Numpad5", 88: "Numpad6", 89: "Numpad7", 91: "Numpad8", 92: "Numpad9", 96: "F5", 97: "F6",
    98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 115: "Home",
    116: "PageUp", 117: "Delete", 118: "F4", 119: "End", 120: "F2", 121: "PageDown", 122: "F1",
    123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
]

/// The same keys by USB keyboard usage, which UIKit reports for a hardware keyboard.
private let hidKeys: [Int: String] = {
    var keys: [Int: String] = [
        0x27: "Digit0", 0x28: "Enter", 0x29: "Escape", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space",
        0x2D: "Minus", 0x2E: "Equal", 0x2F: "BracketLeft", 0x30: "BracketRight", 0x31: "Backslash",
        0x33: "Semicolon", 0x34: "Quote", 0x35: "Backquote", 0x36: "Comma", 0x37: "Period", 0x38: "Slash",
        0x39: "CapsLock", 0x4A: "Home", 0x4B: "PageUp", 0x4C: "Delete", 0x4D: "End", 0x4E: "PageDown",
        0x4F: "ArrowRight", 0x50: "ArrowLeft", 0x51: "ArrowDown", 0x52: "ArrowUp", 0x53: "NumLock",
        0x54: "NumpadDivide", 0x55: "NumpadMultiply", 0x56: "NumpadSubtract", 0x57: "NumpadAdd",
        0x58: "NumpadEnter", 0x62: "Numpad0", 0x63: "NumpadDecimal", 0x67: "NumpadEqual",
        0xE0: "ControlLeft", 0xE1: "ShiftLeft", 0xE2: "AltLeft", 0xE3: "MetaLeft",
        0xE4: "ControlRight", 0xE5: "ShiftRight", 0xE6: "AltRight", 0xE7: "MetaRight",
    ]
    for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { keys[0x04 + offset] = "Key\(letter)" }
    for digit in 1...9 { keys[0x1D + digit] = "Digit\(digit)" }
    for number in 1...12 { keys[0x39 + number] = "F\(number)" }
    for digit in 1...9 { keys[0x58 + digit] = "Numpad\(digit)" }
    return keys
}()
