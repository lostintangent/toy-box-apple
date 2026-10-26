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

    private final class PresentedController: UIViewController {
        var activePresentation: UIViewController?
        override var presentedViewController: UIViewController? { activePresentation }
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
        item.accessibilityIdentifier = "menu-item"
        clip.addSubview(item)
        func measured() -> MobileAutomationTree.Element {
            .init(object: item, label: "Edit", value: "", identifier: "menu-item", traits: .button,
                  frame: item.convert(item.bounds, to: nil))
        }
        #expect(MobileAutomationMenu.isVisible(measured(), matching: "menu-item", in: [window]))
        #expect(!MobileAutomationMenu.isVisible(measured(), matching: "menu-item", in: []))
        item.frame.origin.y = 150
        #expect(!MobileAutomationMenu.isVisible(measured(), matching: "menu-item", in: [window]))
        item.frame.origin.y = 10
        item.isHidden = true
        #expect(!MobileAutomationMenu.isVisible(measured(), matching: "menu-item", in: [window]))
    }

    @Test func menuIdentityTagsOnlyAnIsolatedLeafCopyAndRestoresBeforeDispatch() throws {
        var performed = 0
        var deliveredIdentifier: String?
        let action = UIAction(title: "Edit") { action in
            performed += 1
            deliveredIdentifier = action.accessibilityIdentifier
        }
        action.accessibilityIdentifier = "original-edit"
        let other = UIAction(title: "Other") { _ in }
        other.accessibilityIdentifier = "other"
        let interaction = MenuInteraction(menu: UIMenu(children: [action, other]))
        let marked = try MobileAutomationMenu.mark("Edit", in: interaction)
        defer { marked.restoreIdentifier() }
        let retainedIsCopy = marked.leaf !== action
        #expect(retainedIsCopy)
        #expect(action.accessibilityIdentifier == "original-edit")
        #expect(other.accessibilityIdentifier == "other")
        #expect(marked.element.accessibilityIdentifier == marked.identifier)
        let displayed = try MobileAutomationMenu.leaf(named: "Edit",
                                                       in: MobileAutomationMenu.snapshot(interaction), isVisible: true)
        let displayedIsMarkedCopy = displayed === marked.leaf
        #expect(displayedIsMarkedCopy)
        #expect(performed == 0)
        marked.restoreIdentifier()
        #expect(marked.element.accessibilityIdentifier == "original-edit")
        marked.leaf.performWithSender(nil, target: nil)
        #expect(performed == 1)
        #expect(deliveredIdentifier == "original-edit")
    }

    @Test func aSameTitleBackgroundControlCannotStandInForAnOffscreenMenuLeaf() throws {
        let action = UIAction(title: "Edit") { _ in }
        let interaction = MenuInteraction(menu: UIMenu(children: [action]))
        let marked = try MobileAutomationMenu.mark("Edit", in: interaction)
        defer { marked.restoreIdentifier() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 386, height: 678))
        window.isHidden = false
        defer { window.isHidden = true }
        let background = UIView(frame: CGRect(x: 20, y: 20, width: 100, height: 40))
        background.accessibilityIdentifier = "background-edit"
        let menuItem = UIView(frame: CGRect(x: 20, y: 800, width: 100, height: 40))
        menuItem.accessibilityIdentifier = marked.identifier
        window.addSubview(background)
        window.addSubview(menuItem)
        func measured(_ view: UIView) -> MobileAutomationTree.Element {
            .init(object: view, label: "Edit", value: "", identifier: view.accessibilityIdentifier ?? "",
                  traits: .button, frame: view.convert(view.bounds, to: nil))
        }
        #expect(MobileAutomationMenu.isVisible(measured(background), matching: "background-edit", in: [window]))
        #expect(!MobileAutomationMenu.isVisible(measured(background), matching: marked.identifier, in: [window]))
        #expect(!MobileAutomationMenu.isVisible(measured(menuItem), matching: marked.identifier, in: [window]))
        menuItem.frame.origin.y = 100
        #expect(MobileAutomationMenu.isVisible(measured(menuItem), matching: marked.identifier, in: [window]))
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
