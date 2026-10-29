import AppKit
import ChannelKit
import Foundation
import Testing
@testable import ToyBoxDesktop

@MainActor
@Suite("Dock requests and attention")
struct DockMenuTests {
    private func waiting(_ id: String = "core", sequence: Int = 10, quote: String? = "Should I tag v0.1.4?")
        -> MenuBarStatus.Item {
        .init(id: id, name: id == "core" ? "Core" : id, subtitle: NotificationText.needsReply,
              agent: nil, sequence: sequence, quote: quote)
    }

    @Test func theMenuUsesTheSharedOrderAndRetainsActionsForItsLifetime() throws {
        let requests = [waiting("newest", sequence: 40), waiting("core"), waiting("oldest", sequence: 2)]
        var opened: [MenuBarStatus.Item] = []
        var sent = 0
        var created = 0
        let menu = DockMenu.make(status: .init(waiting: requests), hasCatalog: true,
                                quickSendEnabled: true, canCreateChannel: true,
                                open: { opened.append($0) }, quickSend: { sent += 1 }, newChannel: { created += 1 })
        #expect(menu.items.map(\.title) == [
            "newest: Should I tag v0.1.4?", "Core: Should I tag v0.1.4?", "oldest: Should I tag v0.1.4?",
            "", "Quick Send\u{2026}", "New Channel\u{2026}"
        ])
        #expect(!menu.autoenablesItems)
        #expect(menu.items[3].isSeparatorItem)
        #expect(opened.isEmpty && sent == 0 && created == 0, "Opening the menu must not perform any action.")
        for index in [0, 1, 2, 4, 5] {
            let item = menu.items[index]
            let action = try #require(item.action)
            let target = try #require(item.target as? NSObject)
            target.perform(action, with: item)
        }
        #expect(opened == requests)
        #expect(sent == 1)
        #expect(created == 1)
    }

    @Test func emptyMenusHaveOneDisabledLineAndUnavailableCommandsStayDisabled() {
        let menu = DockMenu.make(status: .init(), hasCatalog: true, quickSendEnabled: false, canCreateChannel: false,
                                open: { _ in Issue.record("There is no request to open.") },
                                quickSend: {}, newChannel: {})
        #expect(menu.items.map(\.title) == ["Nothing needs you", "", "Quick Send\u{2026}", "New Channel\u{2026}"])
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[0].action == nil)
        #expect(!menu.items[2].isEnabled)
        #expect(!menu.items[3].isEnabled)
    }

    @Test func longQuestionsKeepTheirFullPlainTextInHelpAndUnavailablePreviewsStayHonest() {
        let quote = Array(repeating: "A long question about the release", count: 20).joined(separator: "\n")
        let menu = DockMenu.make(status: .init(waiting: [waiting(quote: quote), waiting("unknown", quote: nil)]),
                                hasCatalog: true,
                                quickSendEnabled: true, canCreateChannel: true,
                                open: { _ in }, quickSend: {}, newChannel: {})
        #expect(DockMenu.titleLimit == 60)
        #expect(menu.items[0].title.count <= 60)
        #expect(menu.items[0].title.hasSuffix("\u{2026}"))
        #expect(!menu.items[0].title.contains("\n"))
        #expect(menu.items[0].toolTip == "Core: " + quote.replacingOccurrences(of: "\n", with: " "))
        #expect(menu.items[1].title == "unknown: Needs your reply")
    }

    @Test func launchAndRepeatedOrAnsweredRequestsNeverBounce() {
        var requests: [NSApplication.RequestUserAttentionType] = []
        let attention = DockAttention(allowed: true, enabled: { true }, active: { false }, request: { requests.append($0) })
        attention.update(status: .init(), serverURL: "server", hasCatalog: false)
        attention.update(status: .init(waiting: [waiting()]), serverURL: "server", hasCatalog: true)
        attention.update(status: .init(waiting: [waiting()]), serverURL: "server", hasCatalog: true)
        attention.update(status: .init(), serverURL: "server", hasCatalog: true)
        attention.update(status: .init(waiting: [waiting()]), serverURL: "server", hasCatalog: true)
        #expect(requests.isEmpty)
        attention.update(status: .init(waiting: [waiting(sequence: 11), waiting("another", sequence: 30)]),
                         serverURL: "server", hasCatalog: true)
        #expect(requests == [.informationalRequest])
        attention.update(status: .init(waiting: [waiting(sequence: 11), waiting("another", sequence: 30)]),
                         serverURL: "server", hasCatalog: true)
        #expect(requests == [.informationalRequest])
        attention.update(status: .init(waiting: [waiting(sequence: 12)]), serverURL: "server", hasCatalog: true)
        #expect(requests == [.informationalRequest, .informationalRequest])
    }

    @Test func foregroundAndDisabledRequestsAreRecordedWithoutBackfilling() {
        var enabled = false
        var active = false
        var bounces = 0
        let attention = DockAttention(allowed: true, enabled: { enabled }, active: { active }, request: { _ in bounces += 1 })
        attention.update(status: .init(), serverURL: "server", hasCatalog: true)
        attention.update(status: .init(waiting: [waiting()]), serverURL: "server", hasCatalog: true)
        enabled = true
        attention.update(status: .init(waiting: [waiting()]), serverURL: "server", hasCatalog: true)
        active = true
        attention.update(status: .init(waiting: [waiting(sequence: 11)]), serverURL: "server", hasCatalog: true)
        active = false
        attention.update(status: .init(waiting: [waiting(sequence: 11)]), serverURL: "server", hasCatalog: true)
        #expect(bounces == 0)
        attention.update(status: .init(waiting: [waiting(sequence: 12)]), serverURL: "server", hasCatalog: true)
        #expect(bounces == 1)
    }

    @Test func reconnectAndServerSwitchStartWithQuietBaselines() {
        var bounces = 0
        let attention = DockAttention(allowed: true, enabled: { true }, active: { false }, request: { _ in bounces += 1 })
        attention.update(status: .init(waiting: [waiting()]), serverURL: "server", hasCatalog: true)
        attention.update(status: .init(waiting: [waiting()], unreachableHost: "server"),
                         serverURL: "server", hasCatalog: true)
        attention.update(status: .init(waiting: [waiting(sequence: 20)]), serverURL: "server", hasCatalog: true)
        #expect(bounces == 0)
        attention.update(status: .init(waiting: [waiting(sequence: 21)]), serverURL: "server", hasCatalog: true)
        #expect(bounces == 1)
        attention.update(status: .init(waiting: [waiting(sequence: 30)]), serverURL: "other", hasCatalog: true)
        #expect(bounces == 1)
        attention.update(status: .init(waiting: [waiting(sequence: 31)]), serverURL: "other", hasCatalog: true)
        #expect(bounces == 2)
    }

    @Test func onlyOrdinaryProductionLaunchesCanRequestDockAttention() {
        #expect(DockAttention.isAllowed(.init(), bundleID: "dev.toybox.desktop", environment: [:]))
        for id in [nil, "dev.toybox.desktop.test", "dev.toybox.desktop.benchmark"] {
            #expect(!DockAttention.isAllowed(.init(), bundleID: id, environment: [:]))
        }
        var snapshot = LaunchOptions()
        snapshot.snapshotURL = URL(fileURLWithPath: "/tmp/dock-snapshot.png")
        var benchmark = LaunchOptions()
        benchmark.benchmark = .scroll
        var resize = LaunchOptions()
        resize.resizeBenchmark = .width
        var validation = LaunchOptions()
        validation.quickSendValidation = .trace
        var server = LaunchOptions()
        server.serverURL = "http://127.0.0.1:3210"
        for options in [snapshot, benchmark, resize, validation, server] {
            #expect(!DockAttention.isAllowed(options, bundleID: "dev.toybox.desktop", environment: [:]))
        }
        #expect(!DockAttention.isAllowed(.init(), bundleID: "dev.toybox.desktop",
                                        environment: ["TOY_BOX_SERVER_URL": "http://127.0.0.1:3210"]))
        let attention = DockAttention(allowed: false, enabled: { true }, active: { false },
                                      request: { _ in Issue.record("A validation bundle must never bounce the Dock.") })
        attention.update(status: .init(), serverURL: "server", hasCatalog: true)
        attention.update(status: .init(waiting: [waiting()]), serverURL: "server", hasCatalog: true)
    }

    @Test func olderSequenceReplaysAndResolvedQuotesAreNotNewRequests() {
        var bounces = 0
        let attention = DockAttention(allowed: true, enabled: { true }, active: { false }, request: { _ in bounces += 1 })
        attention.update(status: .init(), serverURL: "server", hasCatalog: true)
        attention.update(status: .init(waiting: [waiting(sequence: 20, quote: nil)]),
                         serverURL: "server", hasCatalog: true)
        #expect(bounces == 1)
        attention.update(status: .init(waiting: [waiting(sequence: 20, quote: "Now resolved")]),
                         serverURL: "server", hasCatalog: true)
        attention.update(status: .init(waiting: [waiting(sequence: 19)]), serverURL: "server", hasCatalog: true)
        #expect(bounces == 1)
        attention.reset()
        attention.update(status: .init(waiting: [waiting(sequence: 21)]), serverURL: "server", hasCatalog: true)
        #expect(bounces == 1)
    }

    @Test func everyWaitingRequestIsListedWithoutTheWorkingSectionLimit() {
        let requests = (1...25).map { waiting("channel-\($0)", sequence: $0) }
        let menu = DockMenu.make(status: .init(waiting: requests), hasCatalog: true,
                                quickSendEnabled: true, canCreateChannel: true,
                                open: { _ in }, quickSend: {}, newChannel: {})
        #expect(menu.items.count == requests.count + 3)
        #expect(menu.items[24].title == "channel-25: Should I tag v0.1.4?")
    }

    @Test func offlineMenusLabelCachedRequestsAndNeverClaimAnUnverifiedEmptyInbox() {
        var request = waiting()
        request.agent = .lead(id: "lead")
        let cached = DockMenu.make(status: .init(waiting: [request], unreachableHost: "server"), hasCatalog: true,
                                  quickSendEnabled: true, canCreateChannel: true,
                                  open: { _ in }, quickSend: {}, newChannel: {})
        #expect(cached.items.map(\.title).prefix(2) == ["May be out of date", "Core: Should I tag v0.1.4?"])
        #expect(!cached.items[0].isEnabled)
        #expect(cached.items[1].isEnabled)
        #expect(cached.items[1].toolTip == "Core: Should I tag v0.1.4?\nLead needs your reply")
        for (status, hasCatalog) in [(MenuBarStatus(), false),
                                     (MenuBarStatus(unreachableHost: "server"), false),
                                     (MenuBarStatus(unreachableHost: "server"), true)] {
            let empty = DockMenu.make(status: status, hasCatalog: hasCatalog,
                                     quickSendEnabled: true, canCreateChannel: true,
                                     open: { _ in }, quickSend: {}, newChannel: {})
            #expect(empty.items.contains { $0.title == "Connect to Toy Box" && !$0.isEnabled })
            #expect(!empty.items.contains { $0.title == "Nothing needs you" })
        }
    }

    @Test func theApplicationDelegateReturnsTheInjectedNativeMenu() {
        let saved = AppDelegate.dockMenuProvider
        defer { AppDelegate.dockMenuProvider = saved }
        let menu = NSMenu(title: "Injected Dock menu")
        AppDelegate.dockMenuProvider = { menu }
        #expect(AppDelegate().applicationDockMenu(NSApplication.shared) === menu)
        AppDelegate.dockMenuProvider = nil
        #expect(AppDelegate().applicationDockMenu(NSApplication.shared) == nil)
    }
}
