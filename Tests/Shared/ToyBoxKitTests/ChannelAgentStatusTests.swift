import ToyBoxKit
import Foundation
import Testing

@Suite("Shared agent status")
struct ChannelAgentStatusTests {
    private struct PresenceCase: Sendable, CustomTestStringConvertible {
        let state: String?
        let message: String?
        let isAvailable: Bool
        let text: String
        let spoken: String
        let cue: ChannelAgent.StatusLine.Cue

        init(_ state: String?, _ message: String? = nil, available: Bool = true, text: String, spoken: String? = nil,
             cue: ChannelAgent.StatusLine.Cue) {
            self.state = state
            self.message = message
            self.isAvailable = available
            self.text = text
            self.spoken = spoken ?? text
            self.cue = cue
        }

        var testDescription: String {
            "\(state ?? "absent")\(message.map { " \($0.debugDescription)" } ?? "")\(isAvailable ? "" : ", disconnected")"
        }
    }

    @Test(arguments: [
        PresenceCase(nil, text: "Status unavailable", cue: .none),
        PresenceCase(nil, available: false, text: "Status unavailable while disconnected", cue: .none),
        PresenceCase("working", "Compiling", available: false, text: "Status unavailable while disconnected", cue: .none),
        PresenceCase("waiting", "Review", available: false, text: "Status unavailable while disconnected", cue: .none),
        PresenceCase("working", nil, text: "Working", cue: .working),
        PresenceCase("working", "", text: "Working", cue: .working),
        PresenceCase("working", "  \n", text: "Working", cue: .working),
        PresenceCase("working", "Compiling", text: "Compiling", spoken: "Working, Compiling", cue: .working),
        PresenceCase("working", "Working on layout", text: "Working on layout", cue: .working),
        PresenceCase("waiting", nil, text: "Waiting", cue: .waiting),
        PresenceCase("waiting", "", text: "Waiting", cue: .waiting),
        PresenceCase("waiting", "Moss's review", text: "Waiting for Moss's review", cue: .waiting),
        PresenceCase("waiting", "Waiting on a test", text: "Waiting on a test", cue: .waiting),
        PresenceCase("idle", "Old message", text: "Idle", cue: .none),
    ])
    private func statusLinesNeverInventIdleAndSpeakTheirStateExactlyOnce(_ expected: PresenceCase) {
        let presence = expected.state.map { ChannelAgentPresence(state: $0, text: expected.message) }
        let status = ChannelAgent.StatusLine(presence: presence, isAvailable: expected.isAvailable)
        #expect(status.text == expected.text)
        #expect(status.spoken == expected.spoken)
        #expect(status.cue == expected.cue)
    }

    @Test func wakeCountdownRoundsUpAndKeepsHoursMinutesAndDueSemantics() {
        let now = Date(timeIntervalSince1970: 0)
        for (seconds, text, spoken) in [
            (-60.0, "Due", "check-in due"), (0, "Due", "check-in due"),
            (0.001, "1m", "checks again in 1 minute"), (60, "1m", "checks again in 1 minute"),
            (60.001, "2m", "checks again in 2 minutes"),
            (480, "8m", "checks again in 8 minutes"),
            (3540, "59m", "checks again in 59 minutes"),
            (3540.001, "1h", "checks again in 1 hour"),
            (3600, "1h", "checks again in 1 hour"),
            (3600.001, "1h 1m", "checks again in 1 hour, 1 minute"),
            (3900, "1h 5m", "checks again in 1 hour, 5 minutes"),
            (90060, "25h 1m", "checks again in 25 hours, 1 minute")
        ] {
            let presentation = ChannelAgent.Countdown(wake: now.addingTimeInterval(seconds), now: now,
                                                            locale: Locale(identifier: "en_US"))
            #expect(presentation.text == text, "\(seconds)")
            #expect(presentation.spoken == spoken, "\(seconds)")
        }
    }

    @Test func wakeCountdownKeepsNarrowUnitsLocalized() {
        let now = Date(timeIntervalSince1970: 0)
        for (locale, text) in [("fr", "8min"), ("ja", "8分")] {
            let presentation = ChannelAgent.Countdown(wake: now.addingTimeInterval(480), now: now,
                                                            locale: Locale(identifier: locale))
            #expect(presentation.text == text)
        }
    }

    @Test func wakeCountdownRequiresLiveWaitingPresenceAndAValidWakeTime() throws {
        let raw = "2026-10-26T23:00:00Z"
        let date = try #require(try? Date(raw, strategy: .iso8601))
        #expect(ChannelAgent.Countdown.wake(for: .init(state: "waiting", wakeAt: raw), isAvailable: true) == date)
        for presence: ChannelAgentPresence? in [
            nil, .init(state: "waiting"), .init(state: "waiting", wakeAt: "invalid"),
            .init(state: "working", wakeAt: raw), .init(state: "idle", wakeAt: raw)
        ] {
            #expect(ChannelAgent.Countdown.wake(for: presence, isAvailable: true) == nil)
        }
        #expect(ChannelAgent.Countdown.wake(for: .init(state: "waiting", wakeAt: raw), isAvailable: false) == nil)
    }

    @Test func aWaitingPresenceKeepsTheWakeCommandItWaitsOnUntilItRuns() throws {
        let json = #"{"state":"waiting","text":"CI","wakeAt":"2026-10-26T23:00:00Z","wakeCommand":"gh run watch 123"}"#
        let agent = ChannelAgent(id: "ada", name: "Ada",
                                 status: try JSONDecoder().decode(ChannelAgent.Status.self, from: Data(json.utf8)))
        #expect(agent.presence(isRunning: false).wakeCommand == "gh run watch 123")
    }
}
