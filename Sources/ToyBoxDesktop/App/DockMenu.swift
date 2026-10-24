import AppKit
import Foundation

@MainActor
enum DockMenu {
    static let titleLimit = 60

    static func make(status: MenuBarStatus, hasCatalog: Bool, quickSendEnabled: Bool, canCreateChannel: Bool,
                     open: @escaping (MenuBarStatus.Item) -> Void,
                     quickSend: @escaping () -> Void, newChannel: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu(title: "Toy Box")
        menu.autoenablesItems = false
        if !hasCatalog {
            menu.addItem(disabled("Connect to Toy Box"))
        } else {
            if status.unreachableHost != nil { menu.addItem(disabled("May be out of date")) }
            if status.waiting.isEmpty {
                menu.addItem(disabled(status.unreachableHost == nil ? "Nothing needs you" : "Connect to Toy Box"))
            }
            for request in status.waiting {
                let question = request.quote?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
                let name = request.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let fullTitle = "\(name): \(question.isEmpty ? MenuBarStatus.needsReply : question)"
                let item = item(NotificationText.truncated(fullTitle, limit: titleLimit)) { open(request) }
                item.toolTip = request.agent.map { "\(fullTitle)\n\($0.name) needs your reply" } ?? fullTitle
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let send = item("Quick Send\u{2026}", action: quickSend)
        send.isEnabled = quickSendEnabled
        menu.addItem(send)
        let create = item("New Channel\u{2026}", action: newChannel)
        create.isEnabled = canCreateChannel
        menu.addItem(create)
        return menu
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let target = Target(action)
        let item = NSMenuItem(title: title, action: #selector(Target.invoke(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }

    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke(_ sender: NSMenuItem) { action() }
    }
}

@MainActor
final class DockAttention {
    static let enabledKey = "bounceDockForRequests"
    private let allowed: Bool
    private let enabled: () -> Bool
    private let active: () -> Bool
    private let request: (NSApplication.RequestUserAttentionType) -> Void
    private var serverURL: String?
    private var needsBaseline = true
    private var seen: [String: Int] = [:]

    init(allowed: Bool, enabled: @escaping () -> Bool, active: @escaping () -> Bool,
         request: @escaping (NSApplication.RequestUserAttentionType) -> Void) {
        self.allowed = allowed
        self.enabled = enabled
        self.active = active
        self.request = request
    }

    static func isAllowed(_ options: LaunchOptions, bundleID: String?,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        bundleID == "dev.toybox.desktop" && !options.isSnapshot && options.benchmark == nil
            && options.resizeBenchmark == nil && options.quickSendValidation == nil
            && options.serverURL == nil && environment["TOY_BOX_SERVER_URL"] == nil
    }

    func reset() {
        serverURL = nil
        needsBaseline = true
        seen = [:]
    }

    func update(status: MenuBarStatus, serverURL: String, hasCatalog: Bool) {
        guard allowed else { return }
        if self.serverURL != serverURL {
            reset()
            self.serverURL = serverURL
        }
        guard hasCatalog, status.unreachableHost == nil else {
            needsBaseline = true
            return
        }
        var hasNewRequest = false
        for item in status.waiting {
            guard let sequence = item.sequence, sequence > 0 else { continue }
            if sequence > (seen[item.id] ?? 0) {
                hasNewRequest = true
                seen[item.id] = sequence
            }
        }
        let wasBaseline = needsBaseline
        needsBaseline = false
        if !wasBaseline, hasNewRequest, enabled(), !active() { request(.informationalRequest) }
    }
}

extension AppModel {
    func makeDockMenu() -> NSMenu {
        let server = serverURL
        return DockMenu.make(status: menuBarStatus, hasCatalog: catalog?.state != nil,
                             quickSendEnabled: quickSend.isEnabled,
                             canCreateChannel: api != nil, open: { [weak self] item in
            guard let self else { return }
            guard self.serverURL == server else {
                NSApplication.shared.presentError(WidgetSnapshotError.differentServer)
                return
            }
            self.activate(channelID: item.id, sequence: item.sequence)
        }, quickSend: { [weak self] in
            self?.quickSend.present()
        }, newChannel: { [weak self] in
            self?.newChannelRequest = UUID()
            self?.activate(channelID: nil)
        })
    }
}
