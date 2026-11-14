import Foundation
import Testing
@testable import ToyBoxKit

struct SystemTextTests {
    @Test func renderedDetailsKeepTheirFormatting() {
        #expect(text(.init(type: "channel_purpose_changed", purpose: " New\n purpose ")) == "Purpose updated New purpose")
        #expect(text(.init(type: "channel_directory_changed", directory: "/a  b\nc")) == "Working directory changed /a  b\nc")
        #expect(text(.init(type: "channel_avatar_changed", avatar: .mark(.init(mark: "M4 12H20", color: "#123456"))))
                == "Avatar updated")
        #expect(text(.init(type: "preview_changed", preview: .init(kind: "url", url: "/preview")))
                == "Preview updated /preview")
        #expect(text(.init(type: "preview_changed", preview: .init(kind: "screen", screenId: "screen")))
                == "Preview updated Screen preview")
        #expect(text(.init(type: "artifact_shared", actor: .user, artifact: .init(
            file: .init(kind: "session", path: "plan.md"), title: "Workshop plan")))
                == "You shared Workshop plan")
        #expect(text(.init(type: "artifact_removed", actor: .user, artifact: .init(
            file: .init(kind: "session", path: "plan.md"), title: "Workshop plan")))
                == "You removed Workshop plan")
        let agents = [ChannelAgent(id: "lead", name: "Lead")]
        #expect(ChannelSystemContent(type: "artifact_removed", actor: .agent("lead")).actorName(agents: agents) == "Lead")
    }

    @Test func groupedMembershipKeepsTheSameCountAndActionWords() throws {
        let joined = ["Ada", "Moss", "Finch"].enumerated().map {
            ChannelSystemContent(type: "member_joined", member: .init(id: "\($0.offset)", name: $0.element))
        }
        #expect(ChannelSystemContent.membership([.init(type: "member_joined")]) == nil)
        #expect(ChannelSystemContent.membership(Array(joined.prefix(1)))?.names == "Ada")
        #expect(ChannelSystemContent.membership(Array(joined.prefix(2)))?.names == "Ada and 1 other")
        let group = try #require(ChannelSystemContent.membership(joined + [.init(type: "member_joined")]))
        #expect(group.names == "Ada and 2 others" && group.action == "joined the channel")
        #expect(ChannelSystemContent.membership([.init(type: "member_left", member: .init(id: "a", name: "Ada"))])?.action
                == "left the channel")
    }

    @Test func groupedArtifactsReadAsOneSentenceForEitherVerb() throws {
        let agents = [ChannelAgent(id: "lead", name: "Lead")]
        func artifact(_ title: String) -> ChannelArtifact {
            .init(file: .init(kind: "session", path: "\(title).md"), title: title)
        }
        func group(_ type: String, _ titles: [String], actor: ChannelMessageSender = .agent("lead")) -> [ChannelMessage] {
            titles.enumerated().map { index, title in
                ChannelMessage(id: "\(type)-\(index)", sequence: index + 1, timestamp: "2026-10-22T12:00:00Z",
                               sender: .system,
                               content: .system(.init(type: type, actor: actor, artifact: artifact(title))))
            }
        }
        func sentence(_ messages: [ChannelMessage]) -> String? {
            ChannelArtifactGroup(messages, agents: agents)?.sentence
        }
        #expect(sentence(group("artifact_removed", ["A"])) == "Lead removed A")
        #expect(sentence(group("artifact_removed", ["A", "B"])) == "Lead removed A and B")
        #expect(sentence(group("artifact_shared", ["A", "B", "C"])) == "Lead shared A, B, and C")
        #expect(sentence(group("artifact_removed", ["A", "B"], actor: .user)) == "You removed A and B")
        #expect(sentence(group("artifact_removed", ["A"]) + group("artifact_shared", ["B"])) == nil)
        #expect(sentence(group("member_joined", ["A"])) == nil)
        #expect(sentence([]) == nil)
        #expect(ChannelSystemContent.phrase(for: .init(type: "artifact_removed")) == "Artifact removed")

        let shared = try #require(ChannelArtifactGroup(group("artifact_shared", ["A", "B", "C"]), agents: agents))
        #expect(shared.verb == .shared && shared.actor == "Lead")
        #expect(shared.entries.map(\.artifact.title) == ["A", "B", "C"])
        #expect(shared.titleOffset(at: 0) == "Lead shared ".utf16.count)
        #expect(shared.sentence.utf16.dropFirst(shared.titleOffset(at: 1)).starts(with: "B, and C".utf16))
        #expect(shared.sentence.utf16.dropFirst(shared.titleOffset(at: 2)).starts(with: "C".utf16))

        let single = group("artifact_removed", ["A"])
        let system = try #require(single.first?.system)
        #expect(system.rendered(agents: agents) == sentence(single))
    }

    @Test func changedValuesCollapseWhitespaceAndTruncateByCharactersNotUTF16() {
        #expect(ChannelSystemContent.value("  a\n b\t c  ") == "a b c")
        #expect(ChannelSystemContent.value(String(repeating: "a", count: 120)) == String(repeating: "a", count: 120))
        #expect(ChannelSystemContent.value(String(repeating: "a", count: 121)) == String(repeating: "a", count: 117) + "...")
        #expect(ChannelSystemContent.value(String(repeating: "\u{1F680}", count: 121))
                == String(repeating: "\u{1F680}", count: 117) + "...")
    }

    @Test func actorsAndUnknownEventDescriptionsPreserveTheirExistingWords() throws {
        let agents = [ChannelAgent(id: "lead", name: "Lead")]
        #expect(ChannelSystemContent(type: "artifact_shared", actor: .agent("lead")).actorName(agents: agents) == "Lead")
        #expect(ChannelSystemContent(type: "artifact_shared", actor: .agent("missing")).actorName(agents: agents)
                == "Deleted agent")
        #expect(ChannelSystemContent(type: "artifact_shared").actorName(agents: agents) == "Deleted agent")
        #expect(text(.init(type: "unknown")) == "Channel updated")
        let future = try JSONDecoder().decode(ChannelSystemContent.self,
                                              from: Data(#"{"type":"future","description":"More\nwords"}"#.utf8))
        #expect(text(future) == "Channel updated\nMore\nwords")
    }

    private func text(_ system: ChannelSystemContent) -> String {
        system.rendered(agents: [])
    }
}
