import ChannelKit
import Observation
import Synchronization
import Testing
@testable import ChannelClient

@MainActor
struct StoreSliceTests {
    private final class Changes: Sendable {
        let names = Mutex<Set<String>>([])
    }

    /// Applies one event and returns the observed properties that announced a change.
    private func changes(in store: ChannelStore, applying event: ChannelObservationEvent) throws -> Set<String> {
        let changes = Changes()
        let reads: [(String, () -> Void)] = [
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
        for (name, read) in reads {
            withObservationTracking(read) { changes.names.withLock { _ = $0.insert(name) } }
        }
        _ = try store.apply(event)
        return changes.names.withLock { $0 }
    }

    private func system(_ sequence: Int, _ content: ChannelSystemContent) -> ChannelMessage {
        .init(id: "s\(sequence)", sequence: sequence, timestamp: "2026-10-01T00:0\(sequence % 10):00Z",
              sender: .system, content: .system(content))
    }

    @Test func eachEventMovesOnlyTheSlicesItChanges() throws {
        let store = ChannelStore(id: "test", api: try MockTransport { _, _ in .init() }.api(), sendJournal: nil)
        var initial = testState(revision: 1, messages: [testMessage(1)])
        initial.members = [ChannelAgent(id: "ana", name: "Ana", role: "Engineer")]
        _ = try store.apply(.init(type: "snapshot", state: initial))
        #expect(store.isLoaded)
        #expect(store.roster.map(\.id) == ["test", "ana"])

        #expect(try changes(in: store, applying: .init(type: "message", revision: 2, message: testMessage(2)))
                == ["state", "messages"])

        let request = ChannelMessage(id: "m3", sequence: 3, timestamp: "2026-10-01T00:03:00Z",
                                     sender: .agent("ana"), content: .text("Which one?"), request: true)
        #expect(try changes(in: store, applying: .init(type: "message", revision: 3, message: request))
                == ["state", "messages", "request", "requestSequence"])
        #expect(store.requestSequence == 3)

        #expect(try changes(in: store, applying: .init(type: "presence", presence: ["ana": .init(state: "working")]))
                == ["state", "presence"])

        let status = ChannelAgentStatus(state: "working", text: "Reading", lookingAt: 3)
        #expect(try changes(in: store, applying: .init(type: "status", revision: 4, agentId: "ana", status: status))
                == ["state", "agentStatuses"])
        #expect(store.agentStatuses["ana"] == status)
        #expect(store.roster.allSatisfy { $0.status == nil })

        #expect(try changes(in: store, applying: .init(type: "tasks", revision: 5,
                                                         tasks: [.init(id: "t1", title: "Ship")]))
                == ["state", "tasks"])

        #expect(try changes(in: store, applying: .init(type: "read", revision: 6, seenThrough: 3)) == ["state"])

        let renamed = system(7, .init(type: "channel_renamed", name: "Renamed"))
        #expect(try changes(in: store, applying: .init(type: "message", revision: 7, message: renamed))
                == ["state", "messages", "details"])
        #expect(store.details?.name == "Renamed")

        let artifact = ChannelArtifact(file: .init(kind: "machine", path: "/tmp/plan.md"), title: "Plan")
        let shared = system(8, .init(type: "artifact_shared", actor: .agent("ana"), artifact: artifact))
        #expect(try changes(in: store, applying: .init(type: "message", revision: 8, message: shared))
                == ["state", "messages", "artifacts", "artifactShares"])
        #expect(store.artifactShares[artifact.file.id]?.sequence == 8)

        let joined = system(9, .init(type: "member_joined", member: .init(id: "bo", name: "Bo")))
        #expect(try changes(in: store, applying: .init(type: "message", revision: 9, message: joined))
                == ["state", "messages", "roster"])
    }

    @Test func aRecoverySnapshotWithTheSameContentMovesOnlyState() throws {
        let store = ChannelStore(id: "test", api: try MockTransport { _, _ in .init() }.api(), sendJournal: nil)
        _ = try store.apply(.init(type: "snapshot", state: testState(revision: 1, messages: [testMessage(1)])))
        let recovered = testState(revision: 40, messages: [testMessage(1)])
        #expect(try changes(in: store, applying: .init(type: "snapshot", state: recovered)) == ["state"])
    }

    @Test func slicesMatchTheStateTheyCameFrom() throws {
        let store = ChannelStore(id: "test", api: try MockTransport { _, _ in .init() }.api(), sendJournal: nil)
        #expect(!store.isLoaded)
        var state = testState(revision: 1, messages: [testMessage(1)])
        state.lead.status = .init(state: "waiting", text: "Review")
        state.channel.purpose = "Plans"
        state.channel.previewUrl = "http://localhost:5173"
        state.presence = ["test": .init(state: "idle")]
        state.routines = [.init(id: "r1", title: "Daily", schedule: "0 9 * * *", prompt: "Summarize")]
        _ = try store.apply(.init(type: "snapshot", state: state))
        #expect(store.details == ChannelDetails(state.channel))
        #expect(store.details?.resolvedPreview == state.channel.resolvedPreview)
        #expect(store.roster == [ChannelAgent.lead(id: "test", profile: testLeadProfile)])
        #expect(store.agentStatuses == ["test": .init(state: "waiting", text: "Review")])
        #expect(store.presence == state.presence)
        #expect(store.messages == state.messages)
        #expect(store.routines == state.routines)
        #expect(store.requestSequence == nil && store.request == nil)
    }
}
