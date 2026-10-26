#if DEBUG
import Foundation
import Testing
import UIKit
@testable import ToyBoxMobile

@MainActor
struct AutomationTests {
    private final class IdentifierOnlyElement: NSObject {
        @objc var accessibilityIdentifier: String?
    }

    private final class MenuDelegate: NSObject, UIContextMenuInteractionDelegate {
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? { nil }
    }

    private final class MenuInteraction: UIContextMenuInteraction {
        private let retainedDelegate: MenuDelegate
        var menu: UIMenu?
        var dismissals = 0

        init(menu: UIMenu) {
            let delegate = MenuDelegate()
            retainedDelegate = delegate
            self.menu = menu
            super.init(delegate: delegate)
        }

        override func updateVisibleMenu(_ block: (UIMenu) -> UIMenu) {
            if let menu { self.menu = block(menu) }
        }

        override func dismissMenu() {
            dismissals += 1
            menu = nil
        }
    }

    @Test func scriptPreservesActionsAndRejectsUnknownOrContradictoryInputs() throws {
        let steps = try JSONDecoder().decode([MobileAutomationStep].self, from: Data("""
            [{"tap":"Studio demo"},{"type":"Hello"},{"wait":"Needs you","timeout":20},
             {"screenshot":"reply","display":"3"},{"back":true},{"fold":false},
             {"action":"Reply","on":"message-12"},{"back":true,"ifPresent":true},
             {"wait":"Replying to Lead","absent":true},{"posture":"folded"},{"posture":"unfolded","timeout":60},
             {"menuAction":"Edit Channel"}]
            """.utf8))
        #expect(steps.map(\.action) == [.tap("Studio demo"), .type("Hello"), .wait("Needs you", absent: false),
                                       .screenshot("reply", "3"), .back(ifPresent: false), .fold(false),
                                       .customAction("Reply", on: "message-12"), .back(ifPresent: true),
                                       .wait("Replying to Lead", absent: true), .posture(.folded), .posture(.unfolded),
                                       .menuAction("Edit Channel")])
        #expect(steps[0].timeout == 12 && steps[2].timeout == 20)
        for invalid in [#"{"tap":"x","wait":"x"}"#, #"{"type":""}"#, #"{"back":false}"#,
                        #"{"fold":1}"#, #"{"tap":"x","display":"1"}"#,
                        #"{"wait":"x","timeout":0}"#, #"{"tap":"x","typo":true}"#,
                        #"{"action":"Reply"}"#, #"{"action":"Reply","on":""}"#,
                        #"{"tap":"Reply","on":"message-12"}"#, #"{"wait":"x","absent":"yes"}"#,
                        #"{"tap":"x","absent":true}"#, #"{"posture":"open"}"#, #"{"posture":0}"#,
                        #"{"posture":"folded","fold":true}"#, #"{"posture":"folded","display":"1"}"#,
                        #"{"menuAction":""}"#, #"{"menuAction":"Edit","on":"menu"}"#,
                        #"{"menuAction":"Edit","tap":"Edit"}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(MobileAutomationStep.self, from: Data(invalid.utf8))
            }
        }
    }

    @Test func menuDispatchExcludesDisabledHiddenOffscreenAndUnopenedSubmenuItems() throws {
        let visible = UIAction(title: "Visible") { _ in }
        let disabled = UIAction(title: "Disabled", attributes: .disabled) { _ in }
        let hidden = UIAction(title: "Hidden", attributes: .hidden) { _ in }
        let unopened = UIAction(title: "Unopened") { _ in }
        let menu = UIMenu(children: [visible, disabled, hidden, UIMenu(title: "More", children: [unopened])])
        let selected = try MobileAutomationMenu.leaf(named: "Visible", in: [menu], isVisible: true)
        let matchesExpectedAction = selected === visible
        #expect(matchesExpectedAction)
        for title in ["Disabled", "Hidden", "Unopened", "Missing"] {
            #expect(throws: MobileAutomationMenu.Failure.self) {
                try MobileAutomationMenu.leaf(named: title, in: [menu], isVisible: true)
            }
        }
        #expect(throws: MobileAutomationMenu.Failure.self) {
            try MobileAutomationMenu.leaf(named: "Visible", in: [menu], isVisible: false)
        }
    }

    @Test func inlineSectionsAreVisibleAndSeparateReportsDoNotDuplicateThem() throws {
        let action = UIAction(title: "Edit") { _ in }
        let inline = UIMenu(options: .displayInline, children: [action])
        let root = UIMenu(children: [inline])
        for menus in [[root], [root, inline]] {
            let selected = try MobileAutomationMenu.leaf(named: "Edit", in: menus, isVisible: true)
            let matchesExpectedAction = selected === action
            #expect(matchesExpectedAction)
        }
    }

    @Test func duplicateVisibleMenuLeavesAreRejectedWithoutDispatching() {
        var performed = 0
        let first = UIAction(title: "Edit") { _ in performed += 1 }
        let second = UIAction(title: "Edit") { _ in performed += 1 }
        let menu = UIMenu(children: [first, second])
        #expect(throws: MobileAutomationMenu.Failure.self) {
            try MobileAutomationMenu.leaf(named: "Edit", in: [menu], isVisible: true)
        }
        #expect(performed == 0)
    }

    @Test func menuVisibilityRequiresTheSelectedWindowAndUnclippedMeasuredCenter() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 386, height: 678))
        window.isHidden = false
        defer { window.isHidden = true }
        let clip = UIView(frame: CGRect(x: 20, y: 20, width: 100, height: 100))
        clip.clipsToBounds = true
        window.addSubview(clip)
        let item = UIView(frame: CGRect(x: 0, y: 10, width: 80, height: 40))
        clip.addSubview(item)
        func measured() -> MobileAutomationTree.Element {
            .init(object: item, label: "Edit", value: "", identifier: "", traits: .button,
                  frame: item.convert(item.bounds, to: nil))
        }
        #expect(MobileAutomationMenu.isVisible(measured(), in: [window]))
        #expect(!MobileAutomationMenu.isVisible(measured(), in: []))
        item.frame.origin.y = 150
        #expect(!MobileAutomationMenu.isVisible(measured(), in: [window]))
        item.frame.origin.y = 10
        item.isHidden = true
        #expect(!MobileAutomationMenu.isVisible(measured(), in: [window]))
    }

    @Test func dismissedMenusAreRejectedAndRetainedActionsUseThePublicLeafAPI() throws {
        var performed = 0
        let action = UIAction(title: "Edit") { _ in performed += 1 }
        let interaction = MenuInteraction(menu: UIMenu(children: [action]))
        let selected = try MobileAutomationMenu.leaf(named: "Edit",
                                                    in: MobileAutomationMenu.snapshot(interaction), isVisible: true)
        interaction.dismissMenu()
        #expect(interaction.dismissals == 1)
        #expect(throws: MobileAutomationMenu.Failure.self) {
            try MobileAutomationMenu.leaf(named: "Edit",
                                         in: MobileAutomationMenu.snapshot(interaction), isVisible: true)
        }
        #expect(performed == 0)
        selected.performWithSender(nil, target: nil)
        #expect(performed == 1)
    }

    @Test func postureRequiresTheVerifiedSceneSizeNotAnArbitraryResize() {
        #expect(MobileAutomationPosture.folded.matches([386, 678]))
        #expect(MobileAutomationPosture.unfolded.matches([871, 669]))
        let otherViewports: [[Double]] = [[], [386], [386, 678, 1], [678, 386], [810, 1080], [0, 0]]
        for viewport in otherViewports {
            #expect(!MobileAutomationPosture.folded.matches(viewport))
            #expect(!MobileAutomationPosture.unfolded.matches(viewport))
        }
        #expect(!MobileAutomationPosture.folded.matches([871, 669]))
        #expect(!MobileAutomationPosture.unfolded.matches([386, 678]))
    }

    @Test func treeUsesAccessibilityContainersWithoutDuplicatingOrExposingHiddenViews() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.isHidden = false
        defer { window.isHidden = true }
        let root = UIView()
        root.accessibilityIdentifier = "message-12"
        let shown = UILabel()
        shown.text = "Studio demo"
        shown.accessibilityLabel = "Studio demo"
        shown.isAccessibilityElement = true
        shown.accessibilityIdentifier = "channel-studio"
        var replies = 0
        shown.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Reply") { _ in
            replies += 1
            return true
        }]
        let hidden = UILabel()
        hidden.text = "Hidden"
        hidden.accessibilityLabel = "Hidden"
        hidden.isAccessibilityElement = true
        hidden.isHidden = true
        let search = UITextField()
        search.isAccessibilityElement = true
        search.accessibilityLabel = ""
        search.accessibilityValue = "Search Channels"
        root.addSubview(shown)
        root.addSubview(hidden)
        root.addSubview(search)
        root.accessibilityElements = [shown, hidden, search]
        window.addSubview(root)
        let tree = MobileAutomationTree(windows: [window])
        #expect(tree.elements.filter { $0.label == "Studio demo" }.count == 1)
        #expect(tree.matching("channel-studio").first?.object === shown)
        #expect(tree.matching("message-12").first?.object === shown)
        #expect(tree.matching("Search Channels").first?.object === search)
        #expect(tree.contains("studio"))
        #expect(!tree.contains("Hidden"))
        let element = try #require(tree.matching("channel-studio").first)
        let action = try #require(element.actions.first)
        #expect(element.description.contains("actions: Reply"))
        #expect(element.perform(action))
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

    @Test func publicIdentifierGetterDoesNotRequireProtocolConformance() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.isHidden = false
        defer { window.isHidden = true }
        let element = IdentifierOnlyElement()
        element.accessibilityIdentifier = "message-15"
        element.accessibilityLabel = "A message"
        element.isAccessibilityElement = true
        window.accessibilityElements = [element]
        #expect(MobileAutomationTree(windows: [window]).matching("message-15").first?.object === element)
    }
}
#endif
