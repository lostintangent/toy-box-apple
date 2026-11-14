import ChannelKit
import Foundation
import Testing

@Suite("Shared agent status")
struct ChannelAgentStatusTests {
    @Test func absentAndDisconnectedPresenceNeverInventIdleOrKeepAnActivityCue() {
        let missing = ChannelAgent.StatusLine(presence: nil, isAvailable: true)
        #expect(missing.text == "Status unavailable" && missing.spoken == missing.text && missing.cue == .none)
        let presences: [ChannelAgentPresence?] = [nil, .init(state: "working", text: "Compiling"),
                                                .init(state: "waiting", text: "Review")]
        for presence in presences {
            let stale = ChannelAgent.StatusLine(presence: presence, isAvailable: false)
            #expect(stale.text == "Status unavailable while disconnected")
            #expect(stale.spoken == stale.text && stale.cue == .none)
        }
    }

    @Test func workingKeepsTheMessageAndSpeaksItsStateExactlyOnce() {
        let emptyMessages: [String?] = [nil, "", "  \n"]
        for message in emptyMessages {
            let status = ChannelAgent.StatusLine(presence: .init(state: "working", text: message), isAvailable: true)
            #expect(status.text == "Working" && status.spoken == "Working" && status.cue == .working)
        }
        let working = ChannelAgent.StatusLine(presence: .init(state: "working", text: "Compiling"), isAvailable: true)
        #expect(working.text == "Compiling" && working.spoken == "Working, Compiling")
        let prefixed = ChannelAgent.StatusLine(presence: .init(state: "working", text: "Working on layout"),
                                                     isAvailable: true)
        #expect(prefixed.spoken == "Working on layout")
    }

    @Test func waitingPreservesAnExistingPrefixAndIdleHasNoCue() {
        let emptyMessages: [String?] = [nil, ""]
        for message in emptyMessages {
            let status = ChannelAgent.StatusLine(presence: .init(state: "waiting", text: message), isAvailable: true)
            #expect(status.text == "Waiting" && status.spoken == "Waiting" && status.cue == .waiting)
        }
        let reason = ChannelAgent.StatusLine(presence: .init(state: "waiting", text: "Moss's review"),
                                                   isAvailable: true)
        #expect(reason.text == "Waiting for Moss's review" && reason.spoken == reason.text)
        let prefixed = ChannelAgent.StatusLine(presence: .init(state: "waiting", text: "Waiting on a test"),
                                                     isAvailable: true)
        #expect(prefixed.text == "Waiting on a test" && prefixed.spoken == prefixed.text)
        let idle = ChannelAgent.StatusLine(presence: .init(state: "idle", text: "Old message"), isAvailable: true)
        #expect(idle.text == "Idle" && idle.spoken == "Idle" && idle.cue == .none)
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
}
