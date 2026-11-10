import AppKit
import ChannelKit
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
                let fullTitle = "\(name): \(question.isEmpty ? ChannelNotification.Content.needsReply : question)"
                let item = item(ChannelNotification.Content.truncated(fullTitle, limit: titleLimit)) { open(request) }
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
    /// The servers whose requests are already known, so a server that comes back doesn't bounce
    /// for the ones that arrived while it was away.
    private var baselined: Set<String> = []
    private var seen: [ChannelTarget: Int] = [:]

    init(allowed: Bool, enabled: @escaping () -> Bool, active: @escaping () -> Bool,
         request: @escaping (NSApplication.RequestUserAttentionType) -> Void) {
        self.allowed = allowed
        self.enabled = enabled
        self.active = active
        self.request = request
    }

    static func isAllowed(_ options: LaunchOptions, bundleID: String?,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        bundleID == "dev.toybox.desktop" && options.allowsUserIntegrations(environment: environment)
    }

    /// Bounces once for requests that are new since the last update. Only servers in `usable`, the
    /// normalized addresses of those loaded and reachable, count.
    func update(status: MenuBarStatus, usable: Set<String>) {
        guard allowed else { return }
        baselined.formIntersection(usable)
        var hasNewRequest = false
        for item in status.waiting where usable.contains(item.target.serverURL) {
            guard let sequence = item.sequence, sequence > 0, sequence > (seen[item.target] ?? 0) else { continue }
            seen[item.target] = sequence
            if baselined.contains(item.target.serverURL) { hasNewRequest = true }
        }
        baselined.formUnion(usable)
        if hasNewRequest, enabled(), !active() { request(.informationalRequest) }
    }
}

extension AppModel {
    func makeDockMenu() -> NSMenu {
        DockMenu.make(status: menuBarStatus, hasCatalog: catalogs.contains(where: \.isLoaded),
                      quickSendEnabled: quickSend.isEnabled,
                      canCreateChannel: api != nil, open: { [weak self] item in
            self?.activate(item.target, sequence: item.sequence)
        }, quickSend: { [weak self] in
            self?.quickSend.present()
        }, newChannel: { [weak self] in
            self?.newChannelRequest = UUID()
            self?.activate(nil)
        })
    }
}
