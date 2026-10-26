import ChannelKit
import SwiftUI
import Testing
@testable import ToyBoxUI

@Suite("Shared agent status")
@MainActor
struct ChannelAgentStatusTests {
    @Test func absentAndDisconnectedPresenceNeverInventIdleOrKeepAnActivityCue() {
        let missing = ChannelAgentStatusPresentation(presence: nil, isLive: true)
        #expect(missing.text == "Status unavailable" && missing.spoken == missing.text && missing.cue == .none)
        let presences: [ChannelAgentPresence?] = [nil, .init(state: "working", text: "Compiling"),
                                                .init(state: "waiting", text: "Review")]
        for presence in presences {
            let stale = ChannelAgentStatusPresentation(presence: presence, isLive: false)
            #expect(stale.text == "Status unavailable while disconnected")
            #expect(stale.spoken == stale.text && stale.cue == .none)
        }
    }

    @Test func workingKeepsTheMessageAndSpeaksItsStateExactlyOnce() {
        let emptyMessages: [String?] = [nil, "", "  \n"]
        for message in emptyMessages {
            let status = ChannelAgentStatusPresentation(presence: .init(state: "working", text: message), isLive: true)
            #expect(status.text == "Working" && status.spoken == "Working" && status.cue == .working)
        }
        let working = ChannelAgentStatusPresentation(presence: .init(state: "working", text: "Compiling"), isLive: true)
        #expect(working.text == "Compiling" && working.spoken == "Working, Compiling")
        let prefixed = ChannelAgentStatusPresentation(presence: .init(state: "working", text: "Working on layout"),
                                                     isLive: true)
        #expect(prefixed.spoken == "Working on layout")
    }

    @Test func waitingPreservesAnExistingPrefixAndIdleHasNoCue() {
        let emptyMessages: [String?] = [nil, ""]
        for message in emptyMessages {
            let status = ChannelAgentStatusPresentation(presence: .init(state: "waiting", text: message), isLive: true)
            #expect(status.text == "Waiting" && status.spoken == "Waiting" && status.cue == .waiting)
        }
        let reason = ChannelAgentStatusPresentation(presence: .init(state: "waiting", text: "Moss's review"),
                                                   isLive: true)
        #expect(reason.text == "Waiting for Moss's review" && reason.spoken == reason.text)
        let prefixed = ChannelAgentStatusPresentation(presence: .init(state: "waiting", text: "Waiting on a test"),
                                                     isLive: true)
        #expect(prefixed.text == "Waiting on a test" && prefixed.spoken == prefixed.text)
        let idle = ChannelAgentStatusPresentation(presence: .init(state: "idle", text: "Old message"), isLive: true)
        #expect(idle.text == "Idle" && idle.spoken == "Idle" && idle.cue == .none)
    }

    @Test func waitingAmberUsesTheApprovedOpaqueSRGBValues() {
        let light = ChannelAgentStatusPresentation.waitingCue(in: .light).resolve(in: EnvironmentValues())
        let dark = ChannelAgentStatusPresentation.waitingCue(in: .dark).resolve(in: EnvironmentValues())
        #expect(abs(light.red - 154.0 / 255) < 0.00001)
        #expect(abs(light.green - 103.0 / 255) < 0.00001 && light.blue == 0 && light.opacity == 1)
        #expect(abs(dark.red - 244.0 / 255) < 0.00001)
        #expect(abs(dark.green - 190.0 / 255) < 0.00001)
        #expect(abs(dark.blue - 102.0 / 255) < 0.00001 && dark.opacity == 1)
    }
}
