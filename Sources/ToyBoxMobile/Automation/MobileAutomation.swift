#if DEBUG
import Foundation
import UIKit

struct MobileAutomationStep: Decodable, Equatable {
    enum Action: Equatable {
        case tap(String), type(String), wait(String, absent: Bool), screenshot(String, String), back(ifPresent: Bool), fold(Bool)
        case customAction(String, on: String)
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
        let actions = names.intersection(["tap", "type", "wait", "screenshot", "back", "fold", "action"])
        guard actions.count == 1, names.isSubset(of: actions.union(["display", "timeout", "ifPresent", "on", "absent"])),
              let name = actions.first, let key = Key(stringValue: name),
              (!names.contains("display") || name == "screenshot"),
              (!names.contains("ifPresent") || name == "back"),
              (!names.contains("absent") || name == "wait"),
              (!names.contains("on") || name == "action") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Each step needs exactly one supported action."))
        }
        timeout = try values.decodeIfPresent(Double.self, forKey: Key(stringValue: "timeout")!) ?? 12
        guard timeout.isFinite, timeout > 0, timeout <= 60 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: values,
                                                  debugDescription: "timeout must be greater than 0 and at most 60 seconds.")
        }
        switch name {
        case "tap", "type", "wait", "screenshot", "action":
            let text = try values.decode(String.self, forKey: key)
            guard !text.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values,
                                                      debugDescription: "Action text must not be empty.")
            }
            switch name {
            case "tap": action = .tap(text)
            case "type": action = .type(text)
            case "wait":
                action = .wait(text, absent: try values.decodeIfPresent(Bool.self, forKey: Key(stringValue: "absent")!) ?? false)
            case "action":
                let target = try values.decode(String.self, forKey: Key(stringValue: "on")!)
                guard !target.isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: values,
                                                          debugDescription: "Custom actions need a nonempty on target.")
                }
                action = .customAction(text, on: target)
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
    @MainActor
    struct Element {
        let object: NSObject
        let label: String
        let value: String
        let identifier: String
        let traits: UIAccessibilityTraits
        let frame: CGRect
        var actions: [UIAccessibilityCustomAction] { object.accessibilityCustomActions ?? [] }

        var description: String {
            [label, value.isEmpty ? "" : "value: \(value)", identifier.isEmpty ? "" : "id: \(identifier)",
             actions.isEmpty ? "" : "actions: \(actions.map { $0.name }.joined(separator: ", "))"]
                .filter { !$0.isEmpty }.joined(separator: " | ")
        }

        func perform(_ action: UIAccessibilityCustomAction) -> Bool {
            if let handler = action.actionHandler { return handler(action) }
            guard let target = action.target else { return false }
            return UIApplication.shared.sendAction(action.selector, to: target, from: action, for: nil)
        }

        func activate() -> Bool {
            if let control = object as? UIControl, !control.isEnabled { return false }
            if object.accessibilityActivate() { return true }
            if let input = object as? UIResponder, input is any UIKeyInput { return input.becomeFirstResponder() }
            if let control = object as? UIControl
                ?? (object as? UIAccessibilityElement)?.accessibilityContainer as? UIControl {
                if control.isEnabled && (control is UIButton || traits.contains(.button)) {
                    control.performPrimaryAction()
                    return true
                }
            }
            if let item = object as? UIBarButtonItem, item.isEnabled, let action = item.action {
                return UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
            }
            return false
        }
    }

    let windows: [UIWindow]
    let elements: [Element]

    init(windows: [UIWindow]) {
        self.windows = windows.filter { !$0.isHidden && $0.alpha > 0 }
        var seen = Set<ObjectIdentifier>()
        var elements: [Element] = []
        func visit(_ object: NSObject) {
            guard seen.count < 5_000, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView, view.isHidden || view.alpha == 0 { return }
            guard !object.accessibilityElementsHidden else { return }
            if object.isAccessibilityElement || !(object.accessibilityCustomActions ?? []).isEmpty {
                let element = Element(object: object, label: object.accessibilityLabel ?? "",
                                      value: object.accessibilityValue ?? "",
                                      identifier: (object as? any UIAccessibilityIdentification)?.accessibilityIdentifier ?? "",
                                      traits: object.accessibilityTraits, frame: object.accessibilityFrame)
                if !element.description.isEmpty { elements.append(element) }
                if object.isAccessibilityElement { return }
            }
            if let children = object.accessibilityElements {
                for case let child as NSObject in children { visit(child) }
            } else {
                let count = object.accessibilityElementCount()
                if count > 0 && count < 5_000 {
                    for index in 0..<count {
                        if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) }
                    }
                }
            }
            if let view = object as? UIView {
                for child in view.subviews { visit(child) }
            }
        }
        for window in self.windows { visit(window) }
        self.elements = elements
    }

    static var current: Self {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        return Self(windows: scenes.flatMap(\.windows))
    }

    var labels: [String] { elements.map(\.description) }
    var viewport: [Double] {
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return [] }
        return [Double(window.bounds.width), Double(window.bounds.height)]
    }

    func matching(_ target: String) -> [Element] {
        let identifiers = elements.filter { $0.identifier == target }
        return identifiers.isEmpty ? elements.filter { $0.label == target } : identifiers
    }

    func contains(_ target: String) -> Bool {
        elements.contains { $0.label.localizedCaseInsensitiveContains(target)
            || $0.value.localizedCaseInsensitiveContains(target) || $0.identifier == target }
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
        let status = Status(state: state, step: index, labels: tree.labels, viewport: tree.viewport, error: error)
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
            guard element.activate() else {
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
        case .back(let ifPresent):
            let tree = try await wait(timeout: step.timeout) {
                let tree = MobileAutomationTree.current
                return tree.viewport.isEmpty ? nil : tree
            }
            let back = tree.matching("BackButton").first
            if back == nil && ifPresent { break }
            let performed = back?.activate()
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
        case .fold:
            let before = MobileAutomationTree.current.viewport
            try await hostAction(timeout: step.timeout)
            _ = try await wait(timeout: step.timeout) {
                let after = MobileAutomationTree.current.viewport
                return !after.isEmpty && after != before ? after : nil
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

    private func settle(timeout: TimeInterval) async throws {
        var previous: [String] = []
        var stable = 0
        _ = try await wait(timeout: timeout) {
            let tree = MobileAutomationTree.current
            for window in tree.windows { window.layoutIfNeeded() }
            let measured = tree.elements.map { "\($0.description) \($0.frame)" } + [String(describing: tree.viewport)]
            stable = measured == previous && !tree.viewport.isEmpty ? stable + 1 : 0
            previous = measured
            return stable >= 4 ? true : nil
        }
    }
}
#endif
