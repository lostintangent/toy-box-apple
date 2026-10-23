import Foundation
import Testing
@testable import ChannelKit

struct ArtifactShareTests {
    @Test func canonicalSnapshotSharesCarryActorTimeAndRevealSequence() throws {
        let url = try #require(Bundle.module.url(forResource: "channel-snapshot", withExtension: "json",
                                                subdirectory: "Fixtures"))
        let state = try JSONDecoder().decode(ChannelState.self, from: Data(contentsOf: url))
        let shares = channelArtifactShares(state.messages)
        #expect(shares.count == 2)
        #expect(shares["session:pixel-designer:Workshop plan.md"]
                == .init(actor: .agent("pixel-designer"), sharedAt: "2026-10-03T20:00:00.000Z", sequence: 10))
        #expect(shares["machine:/demo/Interaction notes.md"]
                == .init(actor: .agent("kit-writer"), sharedAt: "2026-10-03T20:00:00.000Z", sequence: 11))
    }

    @Test func latestDurableSequenceWinsRegardlessOfInputOrderOrTimestamp() {
        let file = WorkspaceFile(kind: "machine", path: "/plan.md")
        let old = ChannelArtifact(file: file, title: "Plan")
        let renamed = ChannelArtifact(id: "legacy-alias", file: file, title: "Renamed", sharedAt: "not-the-event-time")
        let first = share(2, artifact: old, actor: .agent("ada"), timestamp: "2026-10-22T12:00:00Z")
        let latest = share(9, artifact: renamed, actor: .user, timestamp: "2026-10-21T12:00:00Z")
        let expected = ChannelArtifactShare(actor: .user, sharedAt: latest.timestamp, sequence: 9)
        #expect(channelArtifactShares([first, latest])[file.id] == expected)
        #expect(channelArtifactShares([latest, first])[file.id] == expected)
        #expect(channelArtifactShares([latest])["legacy-alias"] == nil)
    }

    @Test func fileIdentityKeepsSessionsAndMachineArtifactsDistinct() {
        let files = [
            WorkspaceFile(kind: "machine", path: "plan.md"),
            WorkspaceFile(kind: "session", sessionId: "one", path: "plan.md"),
            WorkspaceFile(kind: "session", sessionId: "two", path: "plan.md")
        ]
        let messages = files.enumerated().map { index, file in
            share(index + 1, artifact: .init(file: file, title: "Plan"), actor: .agent("member-\(index)"))
        }
        let shares = channelArtifactShares(messages)
        #expect(shares.count == 3)
        #expect(files.enumerated().allSatisfy { index, file in shares[file.id]?.sequence == index + 1 })
    }

    @Test func absentOrInapplicableEventsDoNotInventProvenance() {
        let artifact = ChannelArtifact(file: .init(kind: "machine", path: "/plan.md"), title: "Plan")
        var ordinary = share(3, artifact: artifact)
        ordinary.sender = .agent("kit")
        var otherKind = share(4, artifact: artifact)
        otherKind.content = .system(.init(type: "routine_scheduled", artifact: artifact))
        let missingArtifact = ChannelMessage(id: "missing", sequence: 5, timestamp: "2026-10-22T12:00:00Z",
                                            sender: .system, content: .system(.init(type: "artifact_shared", actor: .user)))
        #expect(channelArtifactShares([ordinary, otherKind, missingArtifact]).isEmpty)
        #expect(channelArtifactShares([])[artifact.id] == nil)
        let missingActor = share(6, artifact: artifact, actor: nil)
        #expect(channelArtifactShares([missingActor])[artifact.id]
                == .init(actor: nil, sharedAt: missingActor.timestamp, sequence: 6))
    }

    private func share(_ sequence: Int, artifact: ChannelArtifact, actor: ChannelMessageSender? = .agent("kit"),
                       timestamp: String = "2026-10-22T12:00:00Z") -> ChannelMessage {
        .init(id: "share-\(sequence)", sequence: sequence, timestamp: timestamp, sender: .system,
              content: .system(.init(type: "artifact_shared", actor: actor, artifact: artifact)))
    }
}
