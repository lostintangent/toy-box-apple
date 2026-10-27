import ChannelKit
import Foundation
import Testing
@testable import ToyBoxMobile

#if DEBUG && targetEnvironment(simulator)
struct MobileActivityFixtureProofTests {
    @Test(arguments: [ChannelActivityPush.Event.update, .end])
    @MainActor func theFixtureCallsTheRealAdapterSeamWithDecodedStateAndDismissal(event: ChannelActivityPush.Event) async throws {
        let timestamp = Date(timeIntervalSince1970: 1793086200)
        let now = timestamp.addingTimeInterval(60 * 60)
        let state = ChannelActivityAttributes.ContentState(
            tasksDone: event == .end ? 3 : 1, tasksTotal: 3, updatedAt: timestamp,
            ending: event == .end ? .completed : nil
        )
        let push = ChannelActivityPush(event: event, timestamp: timestamp, state: state,
                                       staleDate: state.staleDate,
                                       dismissalDate: event == .end ? timestamp.addingTimeInterval(15 * 60) : nil)
        let activity = FixtureActivity()
        let client = ChannelActivityClient(activities: { [activity] }, request: { _, _ in
            Issue.record("Applying a fixture must not start another Activity.")
            throw MobileActivityFixtureProof.Failure.unavailableActivity
        })
        let applied = try await MobileActivityFixtureProof.apply(
            JSONEncoder().encode(push), activityID: activity.id, registrationID: "registration", at: now, client: client
        )
        #expect(applied == push.reanchored(at: now))
        #expect(activity.content == applied.state)
        #expect(activity.updates == (event == .update ? 1 : 0))
        #expect(activity.endings == (event == .end ? 1 : 0))
        #expect(activity.dismissal == applied.dismissalDate)
    }

    @Test(arguments: ["registration", "activity", "inactive"])
    @MainActor func aFixtureCannotTouchAnUnrelatedOrInactiveActivity(mismatch: String) async throws {
        let activity = FixtureActivity()
        activity.isActive = mismatch != "inactive"
        let client = ChannelActivityClient(activities: { [activity] }, request: { _, _ in
            throw MobileActivityFixtureProof.Failure.unavailableActivity
        })
        let state = activity.content
        let push = ChannelActivityPush(event: .update, timestamp: state.updatedAt, state: state, staleDate: state.staleDate)
        let data = try JSONEncoder().encode(push)
        await #expect(throws: MobileActivityFixtureProof.Failure.self) {
            try await MobileActivityFixtureProof.apply(data, activityID: mismatch == "activity" ? "other" : activity.id,
                                                       registrationID: mismatch == "registration" ? "other" : "registration",
                                                       client: client)
        }
        #expect(activity.updates == 0)
        #expect(activity.endings == 0)
    }

    @Test @MainActor func metadataThatTheForegroundAdapterCannotRepresentIsRejected() throws {
        let state = FixtureActivity().content
        let missingFreshness = ChannelActivityPush(event: .update, timestamp: state.updatedAt, state: state)
        #expect(throws: MobileActivityFixtureProof.Failure.self) {
            try MobileActivityFixtureProof.decode(JSONEncoder().encode(missingFreshness), at: .now)
        }
        let missingEnding = ChannelActivityPush(event: .end, timestamp: state.updatedAt, state: state,
                                                staleDate: state.staleDate)
        #expect(throws: MobileActivityFixtureProof.Failure.self) {
            try MobileActivityFixtureProof.decode(JSONEncoder().encode(missingEnding), at: .now)
        }
    }
}

@MainActor
private final class FixtureActivity: ChannelActivitySession {
    let id = "fixture"
    let attributes = ChannelActivityAttributes(channelID: "studio", channelName: "Studio", registrationID: "registration")
    var content = ChannelActivityAttributes.ContentState(
        tasksDone: 1, tasksTotal: 3, updatedAt: Date(timeIntervalSince1970: 1793086200)
    )
    var isActive = true
    var pushToken: Data? { nil }
    var pushTokenUpdates: AsyncStream<Data> { AsyncStream { $0.finish() } }
    var activeUpdates: AsyncStream<Bool> { AsyncStream { $0.finish() } }
    var updates = 0
    var endings = 0
    var dismissal: Date?

    func update(_ state: ChannelActivityAttributes.ContentState) async {
        content = state
        updates += 1
    }

    func end(_ state: ChannelActivityAttributes.ContentState, dismissAt: Date?) async {
        content = state
        dismissal = dismissAt
        endings += 1
        isActive = false
    }
}
#endif
