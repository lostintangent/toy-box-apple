import ChannelKit
import Foundation
import Observation
import Testing
@testable import ChannelClient

/// Reopening a channel that moved far ahead replays everything it missed before `resumed`. The
/// store holds that replay and publishes it with `resumed`, so views catch up in one change.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct ResumeReplayTests {
    /// Counts every change each slice announces, re-arming after each one.
    @MainActor private final class SliceChanges {
        private(set) var counts: [String: Int] = [:]

        init(_ store: ChannelStore) {
            let reads: [(String, @MainActor @Sendable () -> Void)] = [
                ("state", { _ = store.state }),
                ("details", { _ = store.details }),
                ("roster", { _ = store.roster }),
                ("agentStatuses", { _ = store.agentStatuses }),
                ("presence", { _ = store.presence }),
                ("messages", { _ = store.messages }),
                ("request", { _ = store.request }),
                ("requestSequence", { _ = store.requestSequence }),
                ("tasks", { _ = store.tasks }),
                ("artifacts", { _ = store.artifacts }),
                ("artifactShares", { _ = store.artifactShares }),
                ("routines", { _ = store.routines }),
            ]
            for (name, read) in reads { track(name, read) }
        }

        static let everySlice = ["state", "details", "roster", "agentStatuses", "presence", "messages", "request",
                                 "requestSequence", "tasks", "artifacts", "artifactShares", "routines"]

        private func track(_ name: String, _ read: @escaping @MainActor @Sendable () -> Void) {
            withObservationTracking({ read() }) { [weak self] in
                MainActor.assumeIsolated {
                    self?.counts[name, default: 0] += 1
                    self?.track(name, read)
                }
            }
        }
    }

    private let initial: ChannelState = {
        var state = testState(revision: 1, messages: [testMessage(1)])
        state.members = [ChannelAgent(id: "ana", name: "Ana", role: "Engineer")]
        state.channel.seenThrough = 1
        return state
    }()

    private let resumed = ChannelObservationEvent(type: "resumed", presence: ["ana": .init(state: "working")])

    private func system(_ sequence: Int, _ content: ChannelSystemContent) -> ChannelMessage {
        .init(id: "s\(sequence)", sequence: sequence, timestamp: "2026-10-01T00:0\(sequence % 10):00Z",
              sender: .system, content: .system(content))
    }

    /// What a busy channel did while it was closed: 200 messages, then a change to every other slice.
    private func missed() -> [ChannelObservationEvent] {
        var events = (2...201).map { ChannelObservationEvent(type: "message", revision: $0, message: testMessage($0)) }
        let request = ChannelMessage(id: "m202", sequence: 202, timestamp: "2026-10-01T00:02:00Z",
                                     sender: .agent("ana"), content: .text("Which one?"), request: true)
        let artifact = ChannelArtifact(file: .init(kind: "machine", path: "/tmp/plan.md"), title: "Plan")
        let routine = ChannelRoutine(id: "r1", title: "Daily", schedule: "0 9 * * *", prompt: "Summarize")
        events += [
            .init(type: "message", revision: 202, message: request),
            .init(type: "status", revision: 203, agentId: "ana", status: .init(state: "working", text: "Reading")),
            .init(type: "tasks", revision: 204, tasks: [.init(id: "t1", title: "Ship")]),
            .init(type: "message", revision: 205,
                  message: system(205, .init(type: "member_joined", member: .init(id: "bo", name: "Bo")))),
            .init(type: "message", revision: 206,
                  message: system(206, .init(type: "artifact_shared", actor: .agent("ana"), artifact: artifact))),
            .init(type: "message", revision: 207,
                  message: system(207, .init(type: "routine_scheduled", routine: routine))),
            .init(type: "message", revision: 208,
                  message: system(208, .init(type: "channel_renamed", actor: .user, name: "Renamed"))),
        ]
        return events
    }

    private func store(_ mock: MockTransport) throws -> ChannelStore {
        // The grace never ends on its own, so a slow run can't report a failure mid-replay.
        ChannelStore(id: "test", api: try mock.api(), reconnectPolicy: .init(initialDelay: 0.01), sendJournal: nil,
                     sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    }

    /// Connects to the initial snapshot, then closes the channel as a window does.
    private func openAndClose(_ store: ChannelStore, _ mock: MockTransport) async throws {
        store.connect()
        try await eventually { store.phase.isConnected }
        store.disconnect()
        try await eventually(observing: mock) { mock.pendingResponseCount == 0 }
    }

    /// Reopens the channel as `ChannelConnections.hold` does.
    private func reopen(_ store: ChannelStore) {
        store.captureUnreadBoundary()
        store.connect()
    }

    @Test func aReopenedChannelPublishesEverythingItMissedInOneChange() async throws {
        let initial = initial
        let mock = MockTransport { request, _ in
            try .stream(request.url?.query == nil ? [.init(type: "snapshot", state: initial)] : [])
        }
        let store = try store(mock)
        defer { store.disconnect() }
        try await openAndClose(store, mock)

        let changes = SliceChanges(store)
        reopen(store)
        try await eventually(observing: mock) { mock.requests.count == 2 && mock.pendingResponseCount == 1 }
        #expect(mock.requests[1].url?.query == "after=1")

        let events = missed()
        #expect(mock.sendPendingBody(try MockResponse.stream(events).body) == 1)
        // A replay the store rejected would reconnect rather than hold every event.
        try await eventually(observing: mock) { store.heldReplay?.count == events.count || mock.requests.count > 2 }
        #expect(mock.requests.count == 2)
        #expect(changes.counts.isEmpty)
        #expect(store.state == initial)
        #expect(store.unreadAfter == nil)
        #expect(!store.phase.isConnected)

        #expect(mock.sendPendingBody(try MockResponse.stream([resumed]).body) == 1)
        try await eventually { store.phase.isConnected }
        #expect(changes.counts == Dictionary(uniqueKeysWithValues: SliceChanges.everySlice.map { ($0, 1) }))
        #expect(store.heldReplay == nil)
        #expect(store.state?.revision == 208)
        #expect(store.messages.map(\.sequence) == Array(1...202) + Array(205...208))
        #expect(store.requestSequence == 202 && store.request?.id == "m202")
        #expect(store.agentStatuses["ana"]?.text == "Reading")
        #expect(store.presence["ana"]?.state == "working")
        #expect(store.tasks.map(\.id) == ["t1"])
        #expect(store.roster.map(\.id) == ["test", "ana", "bo"])
        #expect(store.artifacts.map(\.title) == ["Plan"])
        #expect(store.artifactShares.count == 1)
        #expect(store.routines.map(\.id) == ["r1"])
        #expect(store.details?.name == "Renamed")
        #expect(store.unreadAfter == 1)

        // Once resumed, each live event publishes as it arrives.
        let live = ChannelObservationEvent(type: "message", revision: 209, message: testMessage(209))
        #expect(mock.sendPendingBody(try MockResponse.stream([live]).body) == 1)
        try await eventually { store.messages.last?.id == "m209" }
        #expect(changes.counts["messages"] == 2)
        #expect(changes.counts["tasks"] == 1)
    }

    @Test func aStreamThatDropsMidReplayPublishesNothingAndReplaysAgain() async throws {
        let initial = initial
        let events = missed()
        let mock = MockTransport { _, count in
            switch count {
            case 1: try .stream([.init(type: "snapshot", state: initial)])
            case 2: try .stream(Array(events.prefix(50)), keepOpen: false)
            default: try .stream([])
            }
        }
        let store = try store(mock)
        defer { store.disconnect() }
        try await openAndClose(store, mock)

        let changes = SliceChanges(store)
        reopen(store)
        try await eventually(observing: mock) { mock.requests.count == 3 && mock.pendingResponseCount == 1 }
        #expect(mock.requests[2].url?.query == "after=1")
        #expect(store.heldReplay?.isEmpty == true)
        #expect(changes.counts.isEmpty)
        #expect(store.state == initial)

        #expect(mock.sendPendingBody(try MockResponse.stream(events + [resumed]).body) == 1)
        try await eventually { store.phase.isConnected }
        #expect(changes.counts == Dictionary(uniqueKeysWithValues: SliceChanges.everySlice.map { ($0, 1) }))
        #expect(store.state?.revision == 208)
        #expect(store.messages.count == 206)
    }

    @Test func aSendTheReplayConfirmsSettlesWhenItsMessageAppears() async throws {
        let initial = initial
        let id = UUID().uuidString
        let mock = MockTransport { request, _ in
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return try .stream(request.url?.query == nil ? [.init(type: "snapshot", state: initial)] : [])
        }
        let store = try store(mock)
        defer { store.disconnect() }
        store.connect()
        try await eventually { store.phase.isConnected }
        await #expect(throws: URLError.self) { try await store.postInBackground(id: id, content: "Ship it") }
        #expect(store.sendAttempts.map(\.phase) == [.deliveryNotConfirmed])
        store.disconnect()
        try await eventually(observing: mock) { mock.pendingResponseCount == 0 }

        reopen(store)
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        let sent = ChannelMessage(id: id, sequence: 2, timestamp: "2026-10-01T00:02:00Z",
                                  sender: .user, content: .text("Ship it"))
        #expect(mock.sendPendingBody(try MockResponse.stream([.init(type: "message", revision: 2, message: sent)]).body) == 1)
        try await eventually { store.heldReplay?.count == 1 }
        // The attempt stays until its message is published, so the send never disappears in between.
        #expect(store.sendAttempts.map(\.id) == [id])
        #expect(store.optimisticMessageIds == [id])

        #expect(mock.sendPendingBody(try MockResponse.stream([resumed]).body) == 1)
        try await eventually { store.phase.isConnected }
        #expect(store.sendAttempts.isEmpty)
        #expect(store.optimisticMessageIds.isEmpty)
        #expect(store.messages.map(\.id) == ["m1", id])
    }

    @Test func aDeletionMidReplayDropsWhatItHeld() async throws {
        let initial = initial
        let events = missed()
        let mock = MockTransport { request, _ in
            try .stream(request.url?.query == nil
                        ? [.init(type: "snapshot", state: initial)]
                        : Array(events.prefix(20)) + [.init(type: "deleted", channelId: "test")])
        }
        let store = try store(mock)
        defer { store.disconnect() }
        try await openAndClose(store, mock)

        let changes = SliceChanges(store)
        reopen(store)
        try await eventually { store.phase == .deleted }
        #expect(store.heldReplay == nil)
        #expect(changes.counts.isEmpty)
        #expect(store.state == initial)
    }
}
