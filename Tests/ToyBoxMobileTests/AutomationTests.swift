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

    private final class ScrollContainer: UIView {
        var directions: [UIAccessibilityScrollDirection] = []
        var handlesScroll = true

        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            directions.append(direction)
            return handlesScroll
        }
    }

    private final class PresentedController: UIViewController {
        var activePresentation: UIViewController?
        override var presentedViewController: UIViewController? { activePresentation }
    }

    private final class EscapeWindow: UIWindow {
        var escapes = 0
        var handlesEscape = true

        override func accessibilityPerformEscape() -> Bool {
            escapes += 1
            return handlesEscape
        }
    }

    private final class UnhandledBackElement: NSObject {
        var activations = 0

        override func accessibilityActivate() -> Bool {
            activations += 1
            return false
        }
    }

    @Test func scriptPreservesActionsAndRejectsUnknownOrContradictoryInputs() throws {
        let steps = try JSONDecoder().decode([MobileAutomationStep].self, from: Data("""
            [{"tap":"Studio demo"},{"type":"Hello"},{"wait":"Needs you","timeout":20},
             {"screenshot":"reply","display":"3"},{"back":true},{"fold":false},
             {"action":"Reply","on":"message-12"},{"back":true,"ifPresent":true},
             {"wait":"Replying to Lead","absent":true},{"scroll":"down","on":"overview-form"},
             {"posture":"folded"},{"posture":"unfolded","timeout":60}]
            """.utf8))
        #expect(steps.map(\.action) == [.tap("Studio demo"), .type("Hello"), .wait("Needs you", absent: false),
                                       .screenshot("reply", "3"), .back(ifPresent: false), .fold(false),
                                       .customAction("Reply", on: "message-12"), .back(ifPresent: true),
                                       .wait("Replying to Lead", absent: true), .scroll(.down, on: "overview-form"),
                                       .posture(.folded), .posture(.unfolded)])
        #expect(steps[0].timeout == 12 && steps[2].timeout == 20)
        for invalid in [#"{"tap":"x","wait":"x"}"#, #"{"type":""}"#, #"{"back":false}"#,
                        #"{"fold":1}"#, #"{"tap":"x","display":"1"}"#,
                        #"{"wait":"x","timeout":0}"#, #"{"tap":"x","typo":true}"#,
                        #"{"action":"Reply"}"#, #"{"action":"Reply","on":""}"#,
                        #"{"tap":"Reply","on":"message-12"}"#, #"{"wait":"x","absent":"yes"}"#,
                        #"{"tap":"x","absent":true}"#, #"{"scroll":"down"}"#,
                        #"{"scroll":"down","on":""}"#, #"{"scroll":"forward","on":"form"}"#,
                        #"{"scroll":"up","on":"form","display":"1"}"#,
                        #"{"posture":"open"}"#, #"{"posture":0}"#,
                        #"{"posture":"folded","fold":true}"#, #"{"posture":"folded","display":"1"}"#,
                        #"{"posture":"folded","scroll":"down","on":"form"}"#,
                        #"{"posture":"folded","on":"form"}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(MobileAutomationStep.self, from: Data(invalid.utf8))
            }
        }
    }

    @Test func scrollingDispatchesOnceToAUniqueContainerAndNeverRetriesAnUnhandledAction() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.isHidden = false
        defer { window.isHidden = true }
        let container = ScrollContainer()
        container.accessibilityIdentifier = "form"
        window.addSubview(container)
        #expect(try !MobileAutomationTree(windows: [window]).scroll(.down, on: "missing"))
        #expect(container.directions.isEmpty)
        #expect(try MobileAutomationTree(windows: [window]).scroll(.down, on: "form"))
        #expect(container.directions == [.down])
        container.handlesScroll = false
        #expect(throws: MobileAutomationTree.ScrollFailure.self) {
            try MobileAutomationTree(windows: [window]).scroll(.up, on: "form")
        }
        #expect(container.directions == [.down, .up])
        let duplicate = ScrollContainer()
        duplicate.accessibilityIdentifier = "form"
        window.addSubview(duplicate)
        #expect(throws: MobileAutomationTree.ScrollFailure.self) {
            try MobileAutomationTree(windows: [window]).scroll(.left, on: "form")
        }
        #expect(container.directions == [.down, .up])
        #expect(duplicate.directions.isEmpty)
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

    @Test func traitSelectionDoesNotInventAWindowOrChooseBetweenAmbiguousWindows() {
        #expect(MobileAutomationTree(windows: []).traits == .unavailable(.missingWindow))
        let first = UIWindow(frame: CGRect(x: 0, y: 0, width: 386, height: 678))
        let second = UIWindow(frame: first.frame)
        first.isHidden = false
        second.isHidden = false
        defer { first.isHidden = true; second.isHidden = true }
        #expect(MobileAutomationTree(windows: [first, second]).traits == .unavailable(.ambiguousWindow))
        #expect(MobileAutomationTree(windows: [first]).traits == .unavailable(.missingContent))
    }

    @Test func effectiveTraitsUseLoadedContentOverridesAndTheActivePresentation() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 386, height: 678))
        let root = PresentedController()
        window.rootViewController = root
        root.loadViewIfNeeded()
        root.view.frame = window.bounds
        window.addSubview(root.view)
        window.overrideUserInterfaceStyle = .light
        root.view.traitOverrides.userInterfaceStyle = .dark
        root.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.isHidden = false
        defer { window.isHidden = true }
        window.updateTraitsIfNeeded()
        #expect(window.traitCollection.userInterfaceStyle == .light)
        let rootTraits = MobileAutomationTree.Traits(
            contentSizeCategory: UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
            interfaceStyle: "dark")
        #expect(MobileAutomationTree(windows: [window]).traits == .available(rootTraits))

        let presented = UIViewController()
        root.activePresentation = presented
        #expect(!presented.isViewLoaded)
        #expect(MobileAutomationTree(windows: [window]).traits == .unavailable(.missingContent))
        #expect(!presented.isViewLoaded)
        presented.loadViewIfNeeded()
        presented.view.frame = window.bounds
        presented.view.traitOverrides.userInterfaceStyle = .light
        presented.view.traitOverrides.preferredContentSizeCategory = .small
        window.addSubview(presented.view)
        window.updateTraitsIfNeeded()
        let presentedTraits = MobileAutomationTree.Traits(
            contentSizeCategory: UIContentSizeCategory.small.rawValue, interfaceStyle: "light")
        #expect(MobileAutomationTree(windows: [window]).traits == .available(presentedTraits))
    }

    @Test func visibleContentMustAgreeOnEffectiveTraitsAndHiddenChildrenDoNotParticipate() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 386, height: 678))
        let root = UIViewController()
        window.rootViewController = root
        root.loadViewIfNeeded()
        root.view.frame = window.bounds
        window.addSubview(root.view)
        var children: [UIViewController] = []
        for index in 0..<2 {
            let child = UIViewController()
            root.addChild(child)
            child.loadViewIfNeeded()
            child.view.frame = CGRect(x: index * 160, y: 0, width: 160, height: 300)
            child.view.traitOverrides.preferredContentSizeCategory = .extraLarge
            child.view.traitOverrides.userInterfaceStyle = index == 0 ? .dark : .light
            root.view.addSubview(child.view)
            child.didMove(toParent: root)
            children.append(child)
        }
        window.isHidden = false
        defer { window.isHidden = true }
        window.updateTraitsIfNeeded()
        #expect(MobileAutomationTree(windows: [window]).traits == .unavailable(.ambiguousContent))
        children[1].view.traitOverrides.userInterfaceStyle = .dark
        window.updateTraitsIfNeeded()
        let expected = MobileAutomationTree.Traits(
            contentSizeCategory: UIContentSizeCategory.extraLarge.rawValue, interfaceStyle: "dark")
        #expect(MobileAutomationTree(windows: [window]).traits == .available(expected))
        children[1].view.traitOverrides.userInterfaceStyle = .light
        children[1].view.isHidden = true
        window.updateTraitsIfNeeded()
        #expect(MobileAutomationTree(windows: [window]).traits == .available(expected))
        let hiddenParent = UIView(frame: root.view.bounds)
        root.view.addSubview(hiddenParent)
        hiddenParent.addSubview(children[1].view)
        children[1].view.isHidden = false
        hiddenParent.isHidden = true
        window.updateTraitsIfNeeded()
        #expect(MobileAutomationTree(windows: [window]).traits == .available(expected))
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

    @Test func aPresentButUnhandledBackTargetFallsBackToOnePublicEscape() {
        let window = EscapeWindow()
        window.isHidden = false
        defer { window.isHidden = true }
        let target = UnhandledBackElement()
        let back = MobileAutomationTree.Element(object: target, label: "Back", value: "", identifier: "BackButton",
                                                traits: .button, frame: .zero)
        #expect(MobileAutomationTree(windows: [window]).activateBack(back))
        #expect(target.activations == 1)
        #expect(window.escapes == 1)
    }

    @Test func aHandledBackActionNeverAlsoEscapes() {
        let window = EscapeWindow()
        window.isHidden = false
        defer { window.isHidden = true }
        let button = UIButton()
        var presses = 0
        button.addAction(UIAction { _ in presses += 1 }, for: .primaryActionTriggered)
        let back = MobileAutomationTree.Element(object: button, label: "Back", value: "", identifier: "BackButton",
                                                traits: .button, frame: .zero)
        #expect(MobileAutomationTree(windows: [window]).activateBack(back))
        #expect(presses == 1)
        #expect(window.escapes == 0)
    }

    @Test func anUnhandledBackAndEscapeCannotReportSuccessAndAnAbsentTargetCanEscape() {
        let window = EscapeWindow()
        window.isHidden = false
        defer { window.isHidden = true }
        window.handlesEscape = false
        let target = UnhandledBackElement()
        let back = MobileAutomationTree.Element(object: target, label: "Back", value: "", identifier: "BackButton",
                                                traits: .button, frame: .zero)
        let tree = MobileAutomationTree(windows: [window])
        #expect(!tree.activateBack(back))
        #expect(target.activations == 1)
        #expect(window.escapes == 1)
        window.handlesEscape = true
        #expect(tree.activateBack(nil))
        #expect(window.escapes == 2)
    }

    @Test func disabledBackTargetsNeverActivateOrEscape() {
        let window = EscapeWindow()
        window.isHidden = false
        defer { window.isHidden = true }
        let button = UIButton()
        button.isEnabled = false
        let tree = MobileAutomationTree(windows: [window])
        let disabledControl = MobileAutomationTree.Element(
            object: button, label: "Back", value: "", identifier: "BackButton", traits: .button, frame: .zero)
        #expect(!tree.activateBack(disabledControl))
        let target = UnhandledBackElement()
        let disabledElement = MobileAutomationTree.Element(
            object: target, label: "Back", value: "", identifier: "BackButton",
            traits: [.button, .notEnabled], frame: .zero)
        #expect(!tree.activateBack(disabledElement))
        #expect(target.activations == 0)
        #expect(window.escapes == 0)
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
