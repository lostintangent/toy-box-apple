#if DEBUG
import Foundation
import Testing
import UIKit
@testable import ToyBoxMobile

@MainActor
struct AutomationTests {
    @Test func scriptPreservesActionsAndRejectsUnknownOrContradictoryInputs() throws {
        let steps = try JSONDecoder().decode([MobileAutomationStep].self, from: Data("""
            [{"tap":"Studio demo"},{"type":"Hello"},{"wait":"Needs you","timeout":20},
             {"screenshot":"reply","display":"3"},{"back":true},{"fold":false},
             {"action":"Reply","on":"message-12"},{"back":true,"ifPresent":true},
             {"wait":"Replying to Lead","absent":true}]
            """.utf8))
        #expect(steps.map(\.action) == [.tap("Studio demo"), .type("Hello"), .wait("Needs you", absent: false),
                                       .screenshot("reply", "3"), .back(ifPresent: false), .fold(false),
                                       .customAction("Reply", on: "message-12"), .back(ifPresent: true),
                                       .wait("Replying to Lead", absent: true)])
        #expect(steps[0].timeout == 12 && steps[2].timeout == 20)
        for invalid in [#"{"tap":"x","wait":"x"}"#, #"{"type":""}"#, #"{"back":false}"#,
                        #"{"fold":1}"#, #"{"tap":"x","display":"1"}"#,
                        #"{"wait":"x","timeout":0}"#, #"{"tap":"x","typo":true}"#,
                        #"{"action":"Reply"}"#, #"{"action":"Reply","on":""}"#,
                        #"{"tap":"Reply","on":"message-12"}"#, #"{"wait":"x","absent":"yes"}"#,
                        #"{"tap":"x","absent":true}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(MobileAutomationStep.self, from: Data(invalid.utf8))
            }
        }
    }

    @Test func treeUsesAccessibilityContainersWithoutDuplicatingOrExposingHiddenViews() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.isHidden = false
        defer { window.isHidden = true }
        let root = UIView()
        root.accessibilityIdentifier = "message-12"
        let shown = UILabel()
        shown.text = "Studio demo"
        shown.accessibilityIdentifier = "channel-studio"
        var replies = 0
        shown.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Reply") { _ in
            replies += 1
            return true
        }]
        let hidden = UILabel()
        hidden.text = "Hidden"
        hidden.isHidden = true
        root.addSubview(shown)
        root.addSubview(hidden)
        root.accessibilityElements = [shown, hidden]
        window.addSubview(root)
        let tree = MobileAutomationTree(windows: [window])
        #expect(tree.elements.filter { $0.label == "Studio demo" }.count == 1)
        #expect(tree.matching("channel-studio").first?.object === shown)
        #expect(tree.matching("message-12").first?.object === shown)
        #expect(tree.contains("studio"))
        #expect(!tree.contains("Hidden"))
        let element = tree.matching("channel-studio").first!
        #expect(element.description.contains("actions: Reply"))
        #expect(element.perform(element.actions[0]))
        #expect(replies == 1)
    }

    @Test func nativeControlsDispatchOneSupportedActionWhenAccessibilityActivationIsUnavailable() {
        let button = UIButton()
        var presses = 0
        button.addAction(UIAction { _ in presses += 1 }, for: .primaryActionTriggered)
        let element = MobileAutomationTree.Element(object: button, label: "Back", value: "", identifier: "",
                                                   traits: .button, frame: .zero)
        #expect(element.activate())
        #expect(presses == 1)
        button.isEnabled = false
        #expect(!element.activate())
        #expect(presses == 1)
    }

    @Test func virtualAccessibilityElementsActivateTheirMeasuredNativeControl() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.isHidden = false
        defer { window.isHidden = true }
        var presses = 0
        let button = UIButton(frame: CGRect(x: 20, y: 30, width: 80, height: 44))
        button.addAction(UIAction { _ in presses += 1 }, for: .primaryActionTriggered)
        window.addSubview(button)
        let virtual = UIAccessibilityElement(accessibilityContainer: window)
        let element = MobileAutomationTree.Element(object: virtual, label: "Back", value: "", identifier: "",
                                                   traits: .button, frame: button.frame)
        #expect(element.activate(in: [window]))
        #expect(presses == 1)
    }
}
#endif
