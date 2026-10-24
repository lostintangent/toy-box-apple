import ChannelClient
import ChannelIntelligence
import ChannelKit
import Foundation
import Testing
@testable import ToyBoxDesktop

@Suite(.serialized) @MainActor
struct MorningDigestTests {
    @Test func deliveryWindowUsesLocalMorningAndNeverRepeatsADay() throws {
        let calendar = calendar()
        let morning = date("2026-10-24T08:00:00Z")
        #expect(MorningDigest.window(now: morning.addingTimeInterval(-1), calendar: calendar, minutes: 480,
                                    lastRun: nil, coveredThrough: nil) == nil)
        let window = try #require(MorningDigest.window(now: morning, calendar: calendar, minutes: 480,
                                                       lastRun: nil, coveredThrough: nil))
        #expect(window.since == morning.addingTimeInterval(-86_400))
        #expect(window.through == morning)
        #expect(MorningDigest.window(now: morning.addingTimeInterval(3 * 3600), calendar: calendar, minutes: 480,
                                    lastRun: nil, coveredThrough: nil) != nil)
        #expect(MorningDigest.window(now: morning.addingTimeInterval(4 * 3600), calendar: calendar, minutes: 480,
                                    lastRun: nil, coveredThrough: nil) == nil)
        #expect(MorningDigest.window(now: morning.addingTimeInterval(3600), calendar: calendar, minutes: 540,
                                    lastRun: morning, coveredThrough: nil) == nil)
        #expect(MorningDigest.window(now: morning, calendar: calendar, minutes: 480,
                                    lastRun: nil, coveredThrough: morning.addingTimeInterval(-3600))?.since
                == morning.addingTimeInterval(-3600))
    }

    @Test func daylightSavingAndTimeZonesStillUseTheLocalClock() throws {
        var pacific = calendar()
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        for value in ["2026-03-08T15:00:00Z", "2026-11-01T16:00:00Z"] {
            let morning = date(value)
            #expect(MorningDigest.window(now: morning, calendar: pacific, minutes: 480,
                                        lastRun: morning.addingTimeInterval(-86_400), coveredThrough: nil) != nil)
            #expect(MorningDigest.window(now: morning.addingTimeInterval(-1), calendar: pacific, minutes: 480,
                                        lastRun: nil, coveredThrough: nil) == nil)
        }
    }

    @Test func onlyAgentActivityWithinTheWindowCountsAndOldRequestsStayOut() throws {
        let now = date("2026-10-24T08:00:00Z")
        let window = MorningDigest.Window(since: now.addingTimeInterval(-3600), through: now)
        var state = state([
            message(1, at: window.since, request: true),
            message(2, at: window.since.addingTimeInterval(1)),
            message(3, at: now, from: .user),
            message(4, at: now.addingTimeInterval(1)),
        ])
        state.channel.requestSequence = 1
        state.request = state.messages.first
        let selected = MorningDigest.selected(state, window: window)
        #expect(selected.messages.map(\.sequence) == [2, 3])
        #expect(selected.channel.requestSequence == nil && selected.request == nil)
        let line = try #require(MorningDigest.line(selected))
        #expect(line.text == "1 new message" && line.count == 1)
        #expect(MorningDigest.line(self.state([message(1, at: now, from: .user)])) == nil)
        let summary = CatchUp(needsYou: nil, changes: [.init(text: "Fixed the layout.", sources: [2])], through: 2)
        #expect(MorningDigest.line(selected, summary: summary)?.text == "Fixed the layout.")
        let content = MorningDigest.ordered([line, .init(channelID: "busy", name: "Busy", count: 12,
                                                         text: "12 new messages")])
        #expect(content.busiest?.channelID == "busy")
        #expect(content.body == "Busy: 12 new messages\nStudio: 1 new message")
        #expect(MorningDigest.ordered([
            .init(channelID: "b", name: "B", count: 2, text: "2 new messages"),
            .init(channelID: "a", name: "A", count: 2, text: "2 new messages"),
        ]).busiest?.channelID == "a")
    }

    @Test func olderHistoryIsReadThroughTheBoundaryAndDeduplicated() async throws {
        let now = date("2026-10-24T08:00:00Z")
        let window = MorningDigest.Window(since: now.addingTimeInterval(-3600), through: now)
        var cursors: [Int] = []
        let initial = state([message(5, at: now)])
        let result = try await MorningDigest.history(initial, window: window) { before in
            cursors.append(before)
            if before == 5 {
                return [message(3, at: now.addingTimeInterval(-60)), message(4, at: now), message(5, at: now)]
            }
            return [message(1, at: window.since), message(2, at: now.addingTimeInterval(-120))]
        }
        #expect(cursors == [5, 3])
        #expect(result.messages.map(\.sequence) == [2, 3, 4, 5])
        #expect(initial.messages.map(\.sequence) == [5])

        var calls = 0
        let exhausted = try await MorningDigest.history(initial, window: window) { _ in
            calls += 1
            return initial.messages
        }
        #expect(calls == 1 && exhausted.messages == initial.messages)
    }

    @Test func schedulingPersistsSuccessAndEmptyMorningsButNotFailures() async throws {
        let suite = "MorningDigestTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "notificationsEnabled")
        var now = date("2026-10-24T09:30:00Z")
        var builds = 0
        var delivered: [String] = []
        var fails = true
        var empty = false
        let digest = MorningDigest(host: .init(
            server: { "server" }, authorized: { true },
            build: { _ in
                builds += 1
                if fails { throw ChannelAPIError.disconnected }
                return empty ? .init(lines: []) : .init(lines: [.init(channelID: "a", name: "Studio", count: 2,
                                                                       text: "2 new messages")])
            },
            deliver: { _, _, id in delivered.append(id) }
        ), defaults: defaults, allowed: true, now: { now }, calendar: calendar)
        await digest.check()
        #expect(digest.error != nil && defaults.object(forKey: MorningDigest.lastRunKey) == nil)
        fails = false
        await digest.check()
        #expect(delivered.count == 1 && digest.error == nil)
        await digest.check()
        #expect(builds == 2 && delivered.count == 1)
        now = now.addingTimeInterval(86_400)
        empty = true
        await digest.check()
        await digest.check()
        #expect(builds == 3 && delivered.count == 1)
    }

    @Test func notificationHasNoSoundBadgeOrReplyAndOpensTheBusiestChannel() throws {
        let digest = MorningDigest.ordered([
            .init(channelID: "b", name: "Docs", count: 1, text: "1 new message"),
            .init(channelID: "a", name: "Studio", count: 7, text: "7 new messages"),
        ])
        let content = try #require(ChannelNotifications.morningDigestContent(digest, serverURL: "https://example.test"))
        #expect(content.title == "Morning digest" && content.subtitle.isEmpty)
        #expect(content.body == "Studio: 7 new messages\nDocs: 1 new message")
        #expect(content.sound == nil && content.badge == nil)
        #expect(content.userInfo["channelID"] as? String == "a")
        #expect(content.userInfo["serverURL"] as? String == "https://example.test")
        #expect(content.categoryIdentifier == MorningDigest.category)
        #expect(NotificationWithdrawal.stale([
            .init(identifier: "digest", serverURL: "https://example.test", channelID: "a",
                  kind: MorningDigest.category, sequence: 0),
        ], channels: [], serverURL: "https://example.test", activeChannelID: "a").isEmpty)
    }

    @Test func serverChangesAndDisablingDuringGenerationCancelDelivery() async throws {
        let suite = "MorningDigestTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "notificationsEnabled")
        var server = "first"
        let digest = MorningDigest(host: .init(
            server: { server }, authorized: { true },
            build: { _ in
                server = "second"
                return .init(lines: [.init(channelID: "a", name: "Studio", count: 2, text: "2 new messages")])
            },
            deliver: { _, _, _ in Issue.record("A stale server's digest must not be delivered") }
        ), defaults: defaults, allowed: true,
           now: { date("2026-10-24T08:00:00Z") }, calendar: calendar)
        await digest.check()
        #expect(defaults.object(forKey: MorningDigest.lastRunKey) == nil)
        let disabled = MorningDigest(host: .init(
            server: { server }, authorized: { true },
            build: { _ in
                defaults.set(false, forKey: MorningDigest.enabledKey)
                return .init(lines: [.init(channelID: "a", name: "Studio", count: 2, text: "2 new messages")])
            },
            deliver: { _, _, _ in Issue.record("Disabled digest must not be delivered") }
        ), defaults: defaults, allowed: true,
           now: { date("2026-10-24T08:00:00Z") }, calendar: calendar)
        await disabled.check()
        #expect(defaults.object(forKey: MorningDigest.lastRunKey) == nil)
    }

    @Test func failedNotificationRemainsRetryableAndConcurrentChecksDoNotDuplicateIt() async throws {
        let suite = "MorningDigestTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "notificationsEnabled")
        var continuation: CheckedContinuation<Void, Never>?
        var attempts = 0
        let digest = MorningDigest(host: .init(
            server: { "server" }, authorized: { true },
            build: { _ in
                if attempts == 0 { await withCheckedContinuation { continuation = $0 } }
                return .init(lines: [.init(channelID: "a", name: "Studio", count: 2, text: "2 new messages")])
            },
            deliver: { _, _, _ in
                attempts += 1
                if attempts == 1 { throw ChannelAPIError.disconnected }
            }
        ), defaults: defaults, allowed: true,
           now: { date("2026-10-24T08:00:00Z") }, calendar: calendar)
        let work = Task { await digest.check() }
        while continuation == nil { await Task.yield() }
        await digest.check()
        #expect(attempts == 0)
        continuation?.resume()
        await work.value
        #expect(attempts == 1 && defaults.object(forKey: MorningDigest.lastRunKey) == nil)
        await digest.check()
        await digest.check()
        #expect(attempts == 2 && digest.error == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOY_BOX_DEMO_URL"] != nil))
    func realFixtureUsesTheCatchUpPathWithoutChangingReadState() async throws {
        let server = try #require(ProcessInfo.processInfo.environment["TOY_BOX_DEMO_URL"])
        let api = try ChannelAPI(serverURL: server)
        let before = try await api.catalog()
        let now = Date.now
        let start = ContinuousClock.now
        let useModel = ProcessInfo.processInfo.environment["TOY_BOX_TEST_DIGEST_MODEL"] == "1"
        let service: any ChannelIntelligenceService = useModel ? LiveChannelIntelligence.shared : NoModel()
        let result = try await MorningDigest.build(
            api: api, window: .init(since: now.addingTimeInterval(-86_400), through: now),
            summarizes: true, intelligence: service
        )
        print("Morning digest (\(ContinuousClock.now - start), model \(useModel)): \(result.body)")
        #expect(!result.lines.isEmpty)
        let after = try await api.catalog()
        #expect(before.channels.map(\.seenThrough) == after.channels.map(\.seenThrough))
    }

    @Test func disabledDeniedAndValidationNeverBuildOrPost() async throws {
        let suite = "MorningDigestTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var authorized = false
        var calls = 0
        let host = MorningDigest.Host(
            server: { "server" }, authorized: { authorized },
            build: { _ in calls += 1; return .init(lines: []) },
            deliver: { _, _, _ in Issue.record("Unexpected notification") }
        )
        let digest = MorningDigest(host: host, defaults: defaults, allowed: true,
                                   now: { date("2026-10-24T08:00:00Z") }, calendar: calendar)
        await digest.check()
        defaults.set(true, forKey: "notificationsEnabled")
        await digest.check()
        authorized = true
        defaults.set(false, forKey: MorningDigest.enabledKey)
        await digest.check()
        #expect(calls == 0)
        defaults.set(true, forKey: MorningDigest.enabledKey)
        let validation = MorningDigest(host: host, defaults: defaults, allowed: false,
                                       now: { date("2026-10-24T08:00:00Z") }, calendar: calendar)
        await validation.check()
        #expect(calls == 0)
        var options = LaunchOptions()
        #expect(MorningDigest.isAllowed(options, bundleID: "dev.toybox.desktop", environment: [:]))
        #expect(!MorningDigest.isAllowed(options, bundleID: "dev.toybox.desktop.test", environment: [:]))
        #expect(!MorningDigest.isAllowed(options, bundleID: "dev.toybox.desktop",
                                        environment: ["TOY_BOX_SERVER_URL": "http://localhost:3210"]))
        options.serverURL = "http://localhost:3210"
        #expect(!MorningDigest.isAllowed(options, bundleID: "dev.toybox.desktop", environment: [:]))
        options = LaunchOptions()
        options.snapshotURL = URL(filePath: "/tmp/digest-snapshot.png")
        #expect(!MorningDigest.isAllowed(options, bundleID: "dev.toybox.desktop", environment: [:]))
        #expect(!MorningDigest.canTest(bundleID: "dev.toybox.desktop.test", options: options,
                                      server: "http://localhost:3210"))
        options = LaunchOptions()
        options.benchmark = .idle
        #expect(!MorningDigest.isAllowed(options, bundleID: "dev.toybox.desktop", environment: [:]))
        options = LaunchOptions()
        options.quickSendValidation = .trace
        #expect(!MorningDigest.isAllowed(options, bundleID: "dev.toybox.desktop", environment: [:]))
        #expect(!MorningDigest.canTest(bundleID: "dev.toybox.desktop.test", options: options,
                                      server: "http://localhost:3100"))
        #expect(NotificationPresentation.options(kind: MorningDigest.category, isActiveChannel: true) == [.banner, .list])
    }

    private struct NoModel: ChannelIntelligenceService {
        var availability: IntelligenceAvailability { .unavailable(.appleIntelligenceNotEnabled) }
        func catchUp(_ request: CatchUpRequest) async -> CatchUpResult { Issue.record("Unavailable model was used"); return .declined }
        func altText(_ request: AltTextRequest) async -> AltText? { nil }
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date { ChannelDates.date(value)! }

    private func state(_ messages: [ChannelMessage]) -> ChannelState {
        ChannelState(revision: 1, channel: Channel(id: "studio", name: "Studio",
                     model: .init(provider: "test", name: "test"), latestSequence: 5,
                     updatedAt: "2026-10-24T08:00:00Z"), lead: .init(id: "lead", name: "Lead"), messages: messages)
    }

    private func message(_ sequence: Int, at: Date, from: ChannelMessageSender = .agent("lead"),
                         request: Bool? = nil) -> ChannelMessage {
        ChannelMessage(id: "\(sequence)", sequence: sequence, timestamp: at.ISO8601Format(), sender: from,
                       content: .text("Finished the layout."), request: request)
    }
}
