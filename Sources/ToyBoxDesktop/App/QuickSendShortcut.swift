import AppKit
import Carbon
import SwiftUI

struct QuickSendShortcut: Codable, Equatable, Sendable {
    static let preferenceKey = "quickSendShortcut"
    static let defaultValue = Self(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey))

    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.modifiers = modifiers
    }

    var validationError: String? {
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        guard keyCode < 128, modifiers & ~allowed == 0 else {
            return "Record a keyboard shortcut using Control, Option or Command."
        }
        guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            return "Include Control, Option or Command so ordinary typing still works."
        }
        guard ![kVK_Return, kVK_Tab, kVK_Delete, kVK_Escape, kVK_ForwardDelete, kVK_ANSI_KeypadEnter,
                kVK_Command, kVK_Shift, kVK_CapsLock, kVK_Option, kVK_Control,
                kVK_RightCommand, kVK_RightShift, kVK_RightOption, kVK_RightControl, kVK_Function]
            .contains(Int(keyCode)) else {
            return "Choose a character, Space, arrow or function key instead."
        }
        if keyCode == kVK_Space,
           [UInt32(cmdKey), UInt32(cmdKey | optionKey), UInt32(controlKey),
            UInt32(controlKey | optionKey)].contains(modifiers) {
            return "That shortcut belongs to Spotlight, input switching or VoiceOver. Choose another."
        }
        return nil
    }

    var modifierLabel: String {
        Self.modifierLabel(modifiers)
    }

    static func modifierLabel(_ modifiers: UInt32) -> String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
    }

    var displayName: String { modifierLabel + keyLabel }

    var keyboardShortcut: KeyboardShortcut? {
        let key: KeyEquivalent?
        switch Int(keyCode) {
        case kVK_Space: key = .space
        case kVK_LeftArrow: key = .leftArrow
        case kVK_RightArrow: key = .rightArrow
        case kVK_UpArrow: key = .upArrow
        case kVK_DownArrow: key = .downArrow
        case kVK_Home: key = .home
        case kVK_End: key = .end
        case kVK_PageUp: key = .pageUp
        case kVK_PageDown: key = .pageDown
        default:
            let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                                kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            if let index = functionKeys.firstIndex(of: Int(keyCode)),
               let scalar = UnicodeScalar(0xF704 + UInt32(index)) {
                key = KeyEquivalent(Character(scalar))
            } else {
                let label = keyLabel.lowercased()
                key = label.count == 1 ? label.first.map { KeyEquivalent($0) } : nil
            }
        }
        guard let key else { return nil }
        var flags: SwiftUI.EventModifiers = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return KeyboardShortcut(key, modifiers: flags)
    }

    var keyLabel: String {
        let special = [
            kVK_Space: "Space", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End",
            kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
            kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
            kVK_F19: "F19", kVK_F20: "F20",
        ]
        if let label = special[Int(keyCode)] { return label }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &deadKey, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

@MainActor
protocol QuickSendHotKeyRegistering: AnyObject {
    func replace(with shortcut: QuickSendShortcut?, onPress: @escaping @MainActor () -> Void) throws
}

struct QuickSendHotKeyError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        if status == eventHotKeyExistsErr {
            return "That shortcut is already in use. Choose another."
        }
        return "Couldn't \(operation) the Quick Send shortcut (macOS error \(status)). Choose another shortcut."
    }
}

@MainActor
final class CarbonQuickSendHotKey: QuickSendHotKeyRegistering {
    private static let signature: OSType = 0x54425153
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var currentID: UInt32 = 0
    private var isDown = false
    private var onPress: (@MainActor () -> Void)?

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    func replace(with shortcut: QuickSendShortcut?, onPress: @escaping @MainActor () -> Void) throws {
        if handler == nil, shortcut != nil {
            var types = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            ]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                              EventParamType(typeEventHotKeyID), nil,
                                              MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr else { return status }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<CarbonQuickSendHotKey>.fromOpaque(context).takeUnretainedValue()
                    guard id.signature == CarbonQuickSendHotKey.signature, id.id == owner.currentID else {
                        return OSStatus(eventNotHandledErr)
                    }
                    if GetEventKind(event) == kEventHotKeyReleased {
                        owner.isDown = false
                    } else if !owner.isDown {
                        owner.isDown = true
                        owner.onPress?()
                    }
                    return noErr
                }
            }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { throw QuickSendHotKeyError(operation: "listen for", status: status) }
        }
        var replacement: EventHotKeyRef?
        let nextID = currentID &+ 1
        if let shortcut {
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                            EventHotKeyID(signature: Self.signature, id: nextID),
                                            GetApplicationEventTarget(), 0, &replacement)
            guard status == noErr else { throw QuickSendHotKeyError(operation: "register", status: status) }
        }
        if let hotKey {
            let status = UnregisterEventHotKey(hotKey)
            guard status == noErr else {
                if let replacement { UnregisterEventHotKey(replacement) }
                throw QuickSendHotKeyError(operation: "change", status: status)
            }
        }
        hotKey = replacement
        currentID = nextID
        isDown = false
        self.onPress = onPress
    }
}
