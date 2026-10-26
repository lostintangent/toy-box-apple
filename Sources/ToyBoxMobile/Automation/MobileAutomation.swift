#if DEBUG
import Foundation
import UIKit

enum MobileAutomationPosture: String, Decodable {
    case folded, unfolded

    var viewport: [Double] {
        switch self {
        case .folded: [386, 678]
        case .unfolded: [871, 669]
        }
    }

    func matches(_ measured: [Double]) -> Bool { measured == viewport }
}

struct MobileAutomationStep: Decodable, Equatable {
    enum ScrollDirection: String, Decodable {
        case up, down, left, right

        var native: UIAccessibilityScrollDirection {
            switch self {
            case .up: .up
            case .down: .down
            case .left: .left
            case .right: .right
            }
        }
    }

    enum Action: Equatable {
        case tap(String), type(String), wait(String, absent: Bool), screenshot(String, String), back(ifPresent: Bool), fold(Bool)
        case customAction(String, on: String)
        case scroll(ScrollDirection, on: String)
        case posture(MobileAutomationPosture)
        case menuAction(String)
    }

    let action: Action
    let timeout: TimeInterval

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        let names = Set(values.allKeys.map(\.stringValue))
        let actions = names.intersection(["tap", "type", "wait", "screenshot", "back", "fold", "action", "scroll", "posture", "menuAction"])
        guard actions.count == 1, names.isSubset(of: actions.union(["display", "timeout", "ifPresent", "on", "absent"])),
              let name = actions.first, let key = Key(stringValue: name),
              (!names.contains("display") || name == "screenshot"),
              (!names.contains("ifPresent") || name == "back"),
              (!names.contains("absent") || name == "wait"),
              (!names.contains("on") || name == "action" || name == "scroll") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Each step needs exactly one supported action."))
        }
        timeout = try values.decodeIfPresent(Double.self, forKey: Key(stringValue: "timeout")!) ?? 12
        guard timeout.isFinite, timeout > 0, timeout <= 60 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: values,
                                                  debugDescription: "timeout must be greater than 0 and at most 60 seconds.")
        }
        switch name {
        case "tap", "type", "wait", "screenshot", "action", "scroll", "menuAction":
            let text = try values.decode(String.self, forKey: key)
            guard !text.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values,
                                                      debugDescription: "Action text must not be empty.")
            }
            switch name {
            case "tap": action = .tap(text)
            case "type": action = .type(text)
            case "menuAction": action = .menuAction(text)
            case "wait":
                action = .wait(text, absent: try values.decodeIfPresent(Bool.self, forKey: Key(stringValue: "absent")!) ?? false)
            case "action", "scroll":
                let target = try values.decode(String.self, forKey: Key(stringValue: "on")!)
                guard !target.isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: values,
                                                          debugDescription: "Custom actions and scrolling need a nonempty on target.")
                }
                if name == "scroll" {
                    guard let direction = ScrollDirection(rawValue: text) else {
                        throw DecodingError.dataCorruptedError(forKey: key, in: values,
                                                              debugDescription: "Scroll direction must be up, down, left or right.")
                    }
                    action = .scroll(direction, on: target)
                } else {
                    action = .customAction(text, on: target)
                }
            default:
                let displayKey = Key(stringValue: "display")!
                let display = try values.decodeIfPresent(String.self, forKey: displayKey)
                action = .screenshot(text, display ?? "1")
            }
        case "back":
            guard try values.decode(Bool.self, forKey: key) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "back must be true.")
            }
            action = .back(ifPresent: try values.decodeIfPresent(Bool.self, forKey: Key(stringValue: "ifPresent")!) ?? false)
        case "posture":
            action = .posture(try values.decode(MobileAutomationPosture.self, forKey: key))
        default:
            action = .fold(try values.decode(Bool.self, forKey: key))
        }
    }
}

@MainActor
enum MobileAutomation {
    private static var started = false

    static func runIfRequested() async {
        guard !started, let path = ProcessInfo.processInfo.environment["TOY_BOX_AUTOMATION_SCRIPT"] else { return }
        started = true
        await MobileAutomationRun(script: URL(filePath: path)).run()
    }
}

@MainActor
struct MobileAutomationTree {
    enum ScrollFailure: Error, CustomStringConvertible {
        case ambiguous(String), unhandled(String)

        var description: String {
            switch self {
            case .ambiguous(let target): "Ambiguous accessibility scroll identifier: \(target)."
            case .unhandled(let target): "Accessibility scrolling was not handled by \(target)."
            }
        }
    }

    @MainActor
    struct Element {
        let object: NSObject
        let label: String
        let value: String
        let identifier: String
        let traits: UIAccessibilityTraits
        let frame: CGRect
        var containerIdentifiers: [String] = []
        var actions: [UIAccessibilityCustomAction] { object.accessibilityCustomActions ?? [] }

        var description: String {
            [label, value.isEmpty ? "" : "value: \(value)", identifier.isEmpty ? "" : "id: \(identifier)",
             containerIdentifiers.isEmpty ? "" : "within: \(containerIdentifiers.joined(separator: "/"))",
             actions.isEmpty ? "" : "actions: \(actions.map { $0.name }.joined(separator: ", "))"]
                .filter { !$0.isEmpty }.joined(separator: " | ")
        }

        func perform(_ action: UIAccessibilityCustomAction) -> Bool {
            if let handler = action.actionHandler { return handler(action) }
            guard let target = action.target else { return false }
            return UIApplication.shared.sendAction(action.selector, to: target, from: action, for: nil)
        }

        private func nativeTarget(in windows: [UIWindow]) -> NSObject? {
            if object is any UIKeyInput || object is UIControl || object is UIBarButtonItem { return object }
            if let container = (object as? UIAccessibilityElement)?.accessibilityContainer as? UIControl {
                return container
            }
            guard !frame.isEmpty, !frame.isInfinite, !frame.isNull else { return nil }
            for window in windows.reversed() {
                let point = window.convert(CGPoint(x: frame.midX, y: frame.midY), from: nil)
                guard window.bounds.contains(point) else { continue }
                var view = window.hitTest(point, with: nil)
                while let current = view {
                    if current is any UIKeyInput || current is UIControl { return current }
                    view = current.superview
                }
            }
            return nil
        }

        func activate(in windows: [UIWindow] = []) -> Bool {
            if traits.contains(.notEnabled) { return false }
            if let control = object as? UIControl, !control.isEnabled { return false }
            if object.accessibilityActivate() { return true }
            guard let target = nativeTarget(in: windows) else { return false }
            if let input = target as? UIResponder, input is any UIKeyInput { return input.becomeFirstResponder() }
            if let control = target as? UIControl {
                if control.isEnabled && (control is UIButton || traits.contains(.button)) {
                    control.performPrimaryAction()
                    return true
                }
            }
            if let item = target as? UIBarButtonItem, item.isEnabled, let action = item.action {
                return UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
            }
            return false
        }
    }

    let windows: [UIWindow]
    let elements: [Element]
    private let identifiedObjects: [String: [NSObject]]

    struct Traits: Encodable, Equatable {
        let contentSizeCategory: String
        let interfaceStyle: String
    }

    enum TraitFailure: String, Error {
        case missingWindow, ambiguousWindow, missingContent, ambiguousContent, treeLimit
    }

    enum TraitObservation: Equatable {
        case available(Traits)
        case unavailable(TraitFailure)
    }

    init(windows: [UIWindow]) {
        self.windows = windows.filter { !$0.isHidden && $0.alpha > 0 }
        var seen = Set<ObjectIdentifier>()
        var elements: [Element] = []
        var identifiedObjects: [String: [NSObject]] = [:]
        func visit(_ object: NSObject, containers: [String]) {
            guard seen.count < 5_000, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView, view.isHidden || view.alpha == 0 { return }
            guard !object.accessibilityElementsHidden else { return }
            let identifier: String
            if let identified = object as? any UIAccessibilityIdentification {
                identifier = identified.accessibilityIdentifier ?? ""
            } else {
                let getter = #selector(getter: UIView.accessibilityIdentifier)
                identifier = object.responds(to: getter)
                    ? object.perform(getter)?.takeUnretainedValue() as? String ?? "" : ""
            }
            if !identifier.isEmpty { identifiedObjects[identifier, default: []].append(object) }
            let descendants = identifier.isEmpty ? containers : containers + [identifier]
            if object.isAccessibilityElement || !(object.accessibilityCustomActions ?? []).isEmpty {
                let element = Element(object: object, label: object.accessibilityLabel ?? "",
                                      value: object.accessibilityValue ?? "",
                                      identifier: identifier, traits: object.accessibilityTraits,
                                      frame: object.accessibilityFrame, containerIdentifiers: containers)
                if !element.description.isEmpty { elements.append(element) }
                if object.isAccessibilityElement { return }
            }
            if let children = object.accessibilityElements {
                for case let child as NSObject in children { visit(child, containers: descendants) }
            } else {
                let count = object.accessibilityElementCount()
                if count > 0 && count < 5_000 {
                    for index in 0..<count {
                        if let child = object.accessibilityElement(at: index) as? NSObject { visit(child, containers: descendants) }
                    }
                }
            }
            if let view = object as? UIView {
                for child in view.subviews { visit(child, containers: descendants) }
            }
        }
        for window in self.windows { visit(window, containers: []) }
        self.elements = elements
        self.identifiedObjects = identifiedObjects
    }

    static var current: Self {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        return Self(windows: scenes.flatMap(\.windows))
    }

    var labels: [String] { elements.map(\.description) }
    var primaryWindow: UIWindow? { windows.first(where: \.isKeyWindow) ?? windows.first }
    var viewport: [Double] {
        guard let window = primaryWindow else { return [] }
        return [Double(window.bounds.width), Double(window.bounds.height)]
    }

    var traits: TraitObservation {
        let keyWindows = windows.filter(\.isKeyWindow)
        guard keyWindows.count <= 1 else { return .unavailable(.ambiguousWindow) }
        guard let window = keyWindows.first ?? (windows.count == 1 ? windows.first : nil) else {
            return .unavailable(windows.isEmpty ? .missingWindow : .ambiguousWindow)
        }
        guard let root = window.rootViewController else { return .unavailable(.missingContent) }
        var seen = Set<ObjectIdentifier>()
        func visible(_ view: UIView) -> Bool {
            guard view.window === window else { return false }
            var region = window.bounds.intersection(view.convert(view.bounds, to: window))
            guard !region.isEmpty, !region.isNull, !region.isInfinite else { return false }
            var ancestor: UIView? = view
            while let current = ancestor {
                guard !current.isHidden, current.alpha > 0 else { return false }
                if current.clipsToBounds {
                    region = region.intersection(current.convert(current.bounds, to: window))
                    guard !region.isEmpty, !region.isNull else { return false }
                }
                ancestor = current.superview
            }
            return true
        }
        func collect(_ controller: UIViewController) throws(TraitFailure) -> [Traits] {
            guard seen.insert(ObjectIdentifier(controller)).inserted, seen.count <= 128 else { throw .treeLimit }
            if let presented = controller.presentedViewController { return try collect(presented) }
            if let navigation = controller as? UINavigationController {
                guard let active = navigation.visibleViewController else { throw .missingContent }
                return try collect(active)
            }
            if let tabs = controller as? UITabBarController {
                guard let active = tabs.selectedViewController else { throw .missingContent }
                return try collect(active)
            }
            guard let view = controller.viewIfLoaded, visible(view) else { throw .missingContent }
            let children = controller.children.filter { $0.viewIfLoaded.map(visible) ?? false }
            if !children.isEmpty {
                var values: [Traits] = []
                for child in children { values.append(contentsOf: try collect(child)) }
                return values
            }
            let collection = view.traitCollection
            let style: String
            switch collection.userInterfaceStyle {
            case .unspecified: style = "unspecified"
            case .light: style = "light"
            case .dark: style = "dark"
            @unknown default: style = "unknown-\(collection.userInterfaceStyle.rawValue)"
            }
            return [Traits(contentSizeCategory: collection.preferredContentSizeCategory.rawValue, interfaceStyle: style)]
        }
        do {
            let values = try collect(root)
            guard let first = values.first else { return .unavailable(.missingContent) }
            guard values.allSatisfy({ $0 == first }) else { return .unavailable(.ambiguousContent) }
            return .available(first)
        } catch {
            return .unavailable(error)
        }
    }

    func matching(_ target: String) -> [Element] {
        let identifiers = elements.filter { $0.identifier == target || $0.containerIdentifiers.contains(target) }
        if !identifiers.isEmpty { return identifiers }
        let labels = elements.filter { $0.label == target }
        return labels.isEmpty ? elements.filter { $0.label.isEmpty && $0.value == target } : labels
    }

    func contains(_ target: String) -> Bool {
        elements.contains { $0.label.localizedCaseInsensitiveContains(target)
            || $0.value.localizedCaseInsensitiveContains(target) || $0.identifier == target
            || $0.containerIdentifiers.contains(target) }
    }

    func scroll(_ direction: MobileAutomationStep.ScrollDirection, on identifier: String) throws -> Bool {
        guard let matches = identifiedObjects[identifier], !matches.isEmpty else { return false }
        guard matches.count == 1, let target = matches.first else { throw ScrollFailure.ambiguous(identifier) }
        guard target.accessibilityScroll(direction.native) else {
            throw ScrollFailure.unhandled("\(identifier) (\(type(of: target)))")
        }
        return true
    }

    var firstResponder: UIResponder? {
        func find(_ view: UIView) -> UIResponder? {
            if view.isFirstResponder { return view }
            for child in view.subviews {
                if let found = find(child) { return found }
            }
            return nil
        }
        return windows.lazy.compactMap(find).first
    }
}

@MainActor
private final class MobileAutomationRun {
    private struct Status: Encodable {
        let state: String
        let step: Int
        let labels: [String]
        let viewport: [Double]
        let traits: MobileAutomationTree.Traits?
        let traitsError: String?
        var error: String?
    }

    private struct Acknowledgement: Decodable {
        let step: Int
        let error: String?
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private let script: URL
    private var index = 0
    private var deadline = ContinuousClock.now
    private var directory: URL { script.deletingLastPathComponent() }

    init(script: URL) { self.script = script }

    func run() async {
        do {
            let steps = try JSONDecoder().decode([MobileAutomationStep].self, from: Data(contentsOf: script))
            guard !steps.isEmpty else { throw Failure("The script must contain at least one step.") }
            for (index, step) in steps.enumerated() {
                self.index = index
                deadline = .now + .milliseconds(Int64(step.timeout * 1_000))
                try publish("running")
                try await perform(step)
            }
            try publish("completed")
        } catch {
            do { try publish("failed", error: String(describing: error)) }
            catch { print("Mobile automation could not publish its failure: \(error)") }
        }
    }

    private func publish(_ state: String, error: String? = nil) throws {
        let tree = MobileAutomationTree.current
        let traits: MobileAutomationTree.Traits?
        let traitsError: String?
        switch tree.traits {
        case .available(let value): traits = value; traitsError = nil
        case .unavailable(let failure): traits = nil; traitsError = failure.rawValue
        }
        let status = Status(state: state, step: index, labels: tree.labels, viewport: tree.viewport,
                            traits: traits, traitsError: traitsError, error: error)
        try JSONEncoder().encode(status).write(to: directory.appending(path: "status.json"), options: .atomic)
    }

    private func perform(_ step: MobileAutomationStep) async throws {
        switch step.action {
        case .tap(let target):
            let element = try await wait(timeout: step.timeout) {
                let matches = MobileAutomationTree.current.matching(target)
                    .filter { !$0.traits.contains(.notEnabled) }
                let buttons = matches.filter { $0.traits.contains(.button) }
                let choices = buttons.count == 1 ? buttons : matches
                guard choices.count <= 1 else { throw Failure("Ambiguous accessibility target: \(target)") }
                return choices.first
            }
            guard element.activate(in: MobileAutomationTree.current.windows) else {
                throw Failure("Accessibility activation was not handled by \(target) (\(type(of: element.object))).")
            }
        case .type(let text):
            let input = try await wait(timeout: step.timeout) {
                MobileAutomationTree.current.firstResponder as? any UIKeyInput
            }
            input.insertText(text)
        case .wait(let target, let absent):
            _ = try await wait(timeout: step.timeout) {
                let tree = MobileAutomationTree.current
                return !tree.viewport.isEmpty && tree.contains(target) != absent ? true : nil
            }
        case .customAction(let name, let target):
            let element = try await wait(timeout: step.timeout) {
                let matches = MobileAutomationTree.current.matching(target).filter {
                    !$0.traits.contains(.notEnabled) && $0.actions.contains { $0.name == name }
                }
                guard matches.count <= 1 else { throw Failure("Ambiguous custom action \(name) on \(target).") }
                return matches.first
            }
            let actions = element.actions.filter { $0.name == name }
            guard actions.count == 1, let action = actions.first, element.perform(action) else {
                throw Failure("Accessibility custom action \(name) was not handled by \(target).")
            }
        case .scroll(let direction, let target):
            _ = try await wait(timeout: step.timeout) {
                try MobileAutomationTree.current.scroll(direction, on: target) ? true : nil
            }
        case .back(let ifPresent):
            let tree = try await wait(timeout: step.timeout) {
                let tree = MobileAutomationTree.current
                return tree.viewport.isEmpty ? nil : tree
            }
            let back = tree.matching("BackButton").first
            if back == nil && ifPresent { break }
            let performed = back?.activate(in: tree.windows)
                ?? tree.windows.reversed().contains { $0.accessibilityPerformEscape() }
            guard performed else {
                let details = back.map { " Back target: \(type(of: $0.object))." } ?? ""
                throw Failure("No visible window handled the accessibility escape action.\(details)")
            }
            if let back {
                _ = try await wait(timeout: step.timeout) {
                    let current = MobileAutomationTree.current.matching("BackButton")
                    return current.allSatisfy { $0.object !== back.object || $0.description != back.description }
                        ? true : nil
                }
            }
        case .screenshot:
            try await settle(timeout: step.timeout)
            try await hostAction(timeout: step.timeout)
        case .menuAction(let title):
            let selection = try MobileAutomationMenu.select(title, in: .current)
            defer { selection.marked.restoreIdentifier() }
            _ = try await wait(timeout: step.timeout) {
                try selection.isVisible(in: .current) ? true : nil
            }
            selection.interaction.dismissMenu()
            _ = try await wait(timeout: step.timeout) {
                MobileAutomationMenu.snapshot(selection.interaction).isEmpty ? true : nil
            }
            try await settle(timeout: step.timeout)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure("Menu dismissal exceeded the step deadline.") }
            try selection.perform(in: .current)
        case .posture(let posture):
            do {
                try await settle(timeout: step.timeout, posture: posture)
            } catch {
                throw Failure("Expected \(posture.rawValue) scene \(posture.viewport), "
                              + "but measured \(MobileAutomationTree.current.viewport). \(error)")
            }
            return
        case .fold:
            let before = MobileAutomationTree.current.viewport
            try await hostAction(timeout: step.timeout)
            do {
                _ = try await wait(timeout: step.timeout) {
                    let after = MobileAutomationTree.current.viewport
                    return !after.isEmpty && after != before ? after : nil
                }
            } catch let failure as Failure {
                throw Failure("Native display power did not change the app scene from \(before). "
                              + "No fold continuity proof was produced. \(failure)")
            }
        }
        try await settle(timeout: step.timeout)
    }

    private func hostAction(timeout: TimeInterval) async throws {
        try publish("ready")
        _ = try await wait(timeout: timeout) {
            let url = self.directory.appending(path: "ack.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil as Bool? }
            let ack = try JSONDecoder().decode(Acknowledgement.self, from: Data(contentsOf: url))
            guard ack.step == self.index else { return nil }
            if let error = ack.error { throw Failure(error) }
            return true
        }
    }

    private func wait<Value>(timeout: TimeInterval, until read: () throws -> Value?) async throws -> Value {
        let deadline = min(self.deadline, ContinuousClock.now + .milliseconds(Int64(timeout * 1_000)))
        repeat {
            try Task.checkCancellation()
            if let result = try read() { return result }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw Failure("Timed out after \(timeout) seconds at step \(index + 1).")
    }

    private func settle(timeout: TimeInterval, posture: MobileAutomationPosture? = nil) async throws {
        var previous: [String] = []
        var stable = 0
        _ = try await wait(timeout: timeout) {
            let tree = MobileAutomationTree.current
            for window in tree.windows { window.layoutIfNeeded() }
            let measured = tree.elements.map { "\($0.description) \($0.frame)" } + [String(describing: tree.viewport)]
            let expected = posture?.matches(tree.viewport) ?? true
            stable = measured == previous && !tree.viewport.isEmpty && expected ? stable + 1 : 0
            previous = measured
            return stable >= 4 ? true : nil
        }
    }
}
#endif
