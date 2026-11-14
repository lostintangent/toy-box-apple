import ChannelKit
import Testing
@testable import ChannelClient

struct ScreenKeyboardTests {
    @Test func onlyAKeyWhosePressWasSentIsReleased() {
        var keyboard = ScreenKeyboard()
        #expect(keyboard.release("KeyA").isEmpty)
        #expect(keyboard.press("KeyA") == [.key("KeyA", down: true)])
        #expect(keyboard.press("KeyA") == [.key("KeyA", down: true)])
        #expect(keyboard.release("KeyA") == [.key("KeyA", down: false)])
        #expect(keyboard.release("KeyA").isEmpty)
    }

    @Test func macModifiersFollowEachSidesFlag() {
        var keyboard = ScreenKeyboard()
        let command: UInt = 0x10_0000
        // Shift was held before control began, so its release goes nowhere.
        #expect(keyboard.modifierChanged(mac: 56, flags: 0x100).isEmpty)
        #expect(keyboard.modifierChanged(mac: 55, flags: command | 0x08) == [.key("MetaLeft", down: true)])
        #expect(keyboard.modifierChanged(mac: 54, flags: command | 0x18) == [.key("MetaRight", down: true)])
        #expect(keyboard.modifierChanged(mac: 55, flags: command | 0x10) == [.key("MetaLeft", down: false)])
        #expect(keyboard.modifierChanged(mac: 54, flags: 0x100) == [.key("MetaRight", down: false)])
        #expect(keyboard.modifierChanged(mac: 62, flags: 0x4_2000) == [.key("ControlRight", down: true)])
        #expect(keyboard.modifierChanged(mac: 57, flags: 0x1_0000)
                == [.key("CapsLock", down: true), .key("CapsLock", down: false)])
        #expect(keyboard.modifierChanged(mac: 57, flags: 0)
                == [.key("CapsLock", down: true), .key("CapsLock", down: false)])
        #expect(keyboard.modifierChanged(mac: 63, flags: 0x80_0000).isEmpty)
    }

    @Test func aPasteLiftsHeldModifiersAroundItsText() {
        var keyboard = ScreenKeyboard()
        #expect(keyboard.paste("hi") == [.text("hi")])
        _ = keyboard.press("ShiftLeft")
        _ = keyboard.press("KeyA")
        _ = keyboard.press("MetaLeft")
        #expect(keyboard.paste("hi") == [.key("ShiftLeft", down: false), .key("MetaLeft", down: false), .text("hi"),
                                         .key("ShiftLeft", down: true), .key("MetaLeft", down: true)])
        #expect(keyboard.paste("").isEmpty)
        #expect(keyboard.release("MetaLeft") == [.key("MetaLeft", down: false)])
    }

    @Test func thePhonesKeyboardTypesTextWithReturnAndDeleteAsKeys() {
        let keyboard = ScreenKeyboard()
        let enter: [Screen.Input] = [.key("Enter", down: true), .key("Enter", down: false)]
        #expect(keyboard.type("hi") == [.text("hi")])
        #expect(keyboard.type("\n") == enter)
        #expect(keyboard.type("hi\nthere\n") == [.text("hi")] + enter + [.text("there")] + enter)
        #expect(keyboard.type("").isEmpty)
        #expect(keyboard.deleteBackward() == [.key("Backspace", down: true), .key("Backspace", down: false)])
    }
}
