import ChannelKit
import Foundation
import Testing
@testable import ToyBoxMobileWidget

struct ChannelActivityTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func theActivityLogoUsesTheAppIconsArcPaths() throws {
        let head = try SVGPath.parse(ChannelActivityLogo.headData)
        let smile = try SVGPath.parse(ChannelActivityLogo.smileData)
        #expect(!head.isEmpty)
        #expect(!smile.isEmpty)
        #expect(head.boundingRect.minX == 193)
        #expect(head.boundingRect.maxX == 831)
        #expect(abs(smile.boundingRect.width - 92.4) < 0.001)
    }

    private func state(working: Int = 0, done: Int = 3, request: Int? = nil,
                       ending: ChannelActivityAttributes.Ending? = nil) -> ChannelActivityAttributes.ContentState {
        .init(workingAgents: (0..<working).map {
            .init(.init(id: "agent-\($0)", name: "Agent \($0)", role: "Engineer"))
        }, tasksDone: done, tasksTotal: 5, waitingRequestSequence: request,
           updatedAt: now, ending: ending)
    }

    @Test func workingAndQuietUseActualCountsWithoutInventingCompletion() {
        let working = ChannelActivityPresentation(state: state(working: 4), isStale: false)
        #expect(working.phase == .working)
        #expect(working.headline == "4 agents working")
        #expect(working.detail == "3 of 5 tasks done")
        #expect(working.compactSymbol == nil)
        let quiet = ChannelActivityPresentation(state: state(), isStale: false)
        #expect(quiet.phase == .quiet)
        #expect(quiet.headline == "No agents working")
        #expect(quiet.detail == working.detail)
        #expect(ChannelActivityPresentation(state: state(done: 5), isStale: false).phase == .quiet)
    }

    @Test func aFreshRequestTakesPrecedenceOverWorkingAndKeepsItsExactSequence() {
        let value = ChannelActivityPresentation(state: state(working: 4, request: 123), isStale: false)
        #expect(value.phase == .request)
        #expect(value.headline == "Needs your reply")
        #expect(value.detail == "3 of 5 tasks done")
        #expect(value.compactSymbol == "questionmark.bubble")
        #expect(value.requestSequence == 123)
    }

    @Test func staleContentHidesLiveCountsAndDoesNotRouteToAnOldRequest() {
        let value = ChannelActivityPresentation(state: state(working: 4, request: 123), isStale: true)
        #expect(value.phase == .stale)
        #expect(value.headline == "May be out of date")
        #expect(value.detail == nil)
        #expect(value.compactSymbol == "clock")
        #expect(value.requestSequence == nil)
    }

    @Test func completionKeepsItsFinalCardEvenAfterItsLastUpdateIsOld() {
        let value = ChannelActivityPresentation(state: state(done: 5, request: 123, ending: .completed), isStale: true)
        #expect(value.phase == .completed)
        #expect(value.headline == "All 5 tasks completed")
        #expect(value.detail == "Following ended")
        #expect(value.compactSymbol == "checkmark.circle")
        #expect(value.requestSequence == nil)
    }

    @Test func everyOtherEndingUsesTheOneApprovedEndedPresentation() {
        let endings: [ChannelActivityAttributes.Ending] = [.channelDeleted, .tasksRemoved]
        for ending in endings {
            let value = ChannelActivityPresentation(state: state(ending: ending), isStale: true)
            #expect(value.phase == .ended)
            #expect(value.headline == "Following ended")
            #expect(value.detail == nil)
            #expect(value.compactSymbol == "stop.circle")
        }
    }
}
