#if DEBUG
import UIKit

@MainActor
enum MobileAutomationMenu {
    enum Failure: Error, CustomStringConvertible {
        case unsupported, treeLimit, inactive, ambiguous, missing(String), duplicate(String), stale

        var description: String {
            switch self {
            case .unsupported: "Visible-menu action dispatch requires the public UIMenuLeaf API."
            case .treeLimit: "The native view tree exceeded 5,000 nodes while locating the active menu."
            case .inactive: "No active visible menu belongs to the current scene."
            case .ambiguous: "Multiple active menus belong to the current scene."
            case .missing(let title): "No enabled, currently visible menu leaf matches \(title)."
            case .duplicate(let title): "Multiple enabled, currently visible menu leaves match \(title)."
            case .stale: "The menu's source scene changed before action dispatch."
            }
        }
    }

    @MainActor
    struct Selection {
        let interaction: UIContextMenuInteraction
        let source: UIView
        let scene: UIWindowScene
        let leaf: any UIMenuLeaf

        func perform(in tree: MobileAutomationTree) throws {
            guard tree.primaryWindow?.windowScene === scene, source.window?.windowScene === scene,
                  scene.activationState == .foregroundActive,
                  !leaf.attributes.contains(.disabled), !leaf.attributes.contains(.hidden),
                  try MobileAutomationMenu.presentations(in: tree).isEmpty else { throw Failure.stale }
            guard #available(iOS 16.0, *) else { throw Failure.unsupported }
            leaf.performWithSender(source, target: nil)
        }
    }

    static func snapshot(_ interaction: UIContextMenuInteraction) -> [UIMenu] {
        var menus: [UIMenu] = []
        interaction.updateVisibleMenu { menu in
            menus.append(menu)
            return menu
        }
        return menus
    }

    static func leaf(named title: String, in menus: [UIMenu], isVisible: Bool) throws -> any UIMenuLeaf {
        guard #available(iOS 16.0, *) else { throw Failure.unsupported }
        guard !menus.isEmpty else { throw Failure.inactive }
        let reported = Set(menus.map(\.identifier))
        var matches: [any UIMenuLeaf] = []
        func visit(_ menu: UIMenu) {
            for child in menu.children {
                if let leaf = child as? any UIMenuLeaf, leaf.title == title,
                   !leaf.attributes.contains(.disabled), !leaf.attributes.contains(.hidden) {
                    matches.append(leaf)
                } else if let inline = child as? UIMenu, inline.options.contains(.displayInline),
                          !reported.contains(inline.identifier) {
                    visit(inline)
                }
            }
        }
        for menu in menus { visit(menu) }
        guard isVisible, !matches.isEmpty else { throw Failure.missing(title) }
        guard matches.count == 1, let leaf = matches.first else { throw Failure.duplicate(title) }
        return leaf
    }

    static func select(_ title: String, in tree: MobileAutomationTree) throws -> Selection {
        guard let scene = tree.primaryWindow?.windowScene, scene.activationState == .foregroundActive else {
            throw Failure.inactive
        }
        let presentations = try presentations(in: tree)
        guard !presentations.isEmpty else { throw Failure.inactive }
        guard presentations.count == 1, let presentation = presentations.first else { throw Failure.ambiguous }
        guard let source = presentation.interaction.view else { throw Failure.stale }
        let sceneTree = MobileAutomationTree(windows: tree.windows.filter { $0.windowScene === scene })
        let visible = sceneTree.elements.contains { $0.label == title && isVisible($0, in: sceneTree.windows) }
        let leaf = try leaf(named: title, in: presentation.menus, isVisible: visible)
        return Selection(interaction: presentation.interaction, source: source, scene: scene, leaf: leaf)
    }

    static func isVisible(_ element: MobileAutomationTree.Element, in windows: [UIWindow]) -> Bool {
        guard let view = element.object as? UIView
                ?? (element.object as? UIAccessibilityElement)?.accessibilityContainer as? UIView,
              let window = view.window, windows.contains(where: { $0 === window }),
              !element.frame.isEmpty, !element.frame.isNull, !element.frame.isInfinite else { return false }
        let point = window.convert(CGPoint(x: element.frame.midX, y: element.frame.midY), from: nil)
        guard window.bounds.contains(point) else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0 else { return false }
            if current.clipsToBounds && !current.bounds.contains(current.convert(point, from: window)) { return false }
            ancestor = current.superview
        }
        return true
    }

    private static func presentations(in tree: MobileAutomationTree) throws
        -> [(interaction: UIContextMenuInteraction, menus: [UIMenu])] {
        guard let scene = tree.primaryWindow?.windowScene, scene.activationState == .foregroundActive else {
            throw Failure.inactive
        }
        var interactions: [UIContextMenuInteraction] = []
        var seen = Set<ObjectIdentifier>()
        var visited = 0
        func visit(_ view: UIView) throws {
            guard !view.isHidden, view.alpha > 0 else { return }
            visited += 1
            guard visited <= 5_000 else { throw Failure.treeLimit }
            var attached = view.interactions.compactMap { $0 as? UIContextMenuInteraction }
            if let interaction = (view as? UIControl)?.contextMenuInteraction { attached.append(interaction) }
            for interaction in attached where seen.insert(ObjectIdentifier(interaction)).inserted {
                interactions.append(interaction)
            }
            for child in view.subviews { try visit(child) }
        }
        for window in tree.windows where window.windowScene === scene { try visit(window) }
        return interactions.compactMap { interaction in
            let menus = snapshot(interaction)
            return menus.isEmpty ? nil : (interaction, menus)
        }
    }
}
#endif
