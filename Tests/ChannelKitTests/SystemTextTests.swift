import Foundation
import Testing
@testable import ChannelKit

struct SystemTextTests {
    @Test func renderedDetailsKeepTheirFormattingAndPreviewPriority() {
        #expect(text(.init(type: "channel_purpose_changed", purpose: " New\n purpose ")) == "Purpose updated New purpose")
        #expect(text(.init(type: "channel_directory_changed", directory: "/a  b\nc")) == "Working directory changed /a  b\nc")
        #expect(text(.init(type: "preview_changed", previewUrl: "/preview")) == "Preview updated /preview")
        #expect(text(.init(type: "preview_changed", preview: .init(kind: "screen", screenId: "screen"),
                          previewUrl: "/old-preview")) == "Preview updated Open screen in Toy Box")
        #expect(text(.init(type: "artifact_shared", actor: .user, artifact: .init(
            file: .init(kind: "session", path: "plan.md"), title: "Workshop plan")))
                == "You shared Workshop plan")
    }

    @Test func groupedMembershipKeepsTheSameCountAndActionWords() throws {
        let joined = ["Ada", "Moss", "Finch"].enumerated().map {
            ChannelSystemContent(type: "member_joined", member: .init(id: "\($0.offset)", name: $0.element))
        }
        #expect(ChannelSystemText.membership([.init(type: "member_joined")]) == nil)
        #expect(ChannelSystemText.membership(Array(joined.prefix(1)))?.names == "Ada")
        #expect(ChannelSystemText.membership(Array(joined.prefix(2)))?.names == "Ada and 1 other")
        let group = try #require(ChannelSystemText.membership(joined + [.init(type: "member_joined")]))
        #expect(group.names == "Ada and 2 others" && group.action == "joined the channel")
        #expect(ChannelSystemText.membership([.init(type: "member_left", member: .init(id: "a", name: "Ada"))])?.action
                == "left the channel")
    }

    @Test func changedValuesCollapseWhitespaceAndTruncateByCharactersNotUTF16() {
        #expect(ChannelSystemText.value("  a\n b\t c  ") == "a b c")
        #expect(ChannelSystemText.value(String(repeating: "a", count: 120)) == String(repeating: "a", count: 120))
        #expect(ChannelSystemText.value(String(repeating: "a", count: 121)) == String(repeating: "a", count: 117) + "...")
        #expect(ChannelSystemText.value(String(repeating: "\u{1F680}", count: 121))
                == String(repeating: "\u{1F680}", count: 117) + "...")
    }

    @Test func actorsAndUnknownEventDescriptionsPreserveTheirExistingWords() throws {
        let agents = [ChannelAgent(id: "lead", name: "Lead")]
        #expect(ChannelSystemText.actor(.init(type: "artifact_shared", actor: .agent("lead")), agents: agents) == "Lead")
        #expect(ChannelSystemText.actor(.init(type: "artifact_shared", actor: .agent("missing")), agents: agents)
                == "Deleted agent")
        #expect(ChannelSystemText.actor(nil, agents: agents) == "Deleted agent")
        #expect(text(.init(type: "unknown")) == "Channel updated")
        let future = try JSONDecoder().decode(ChannelSystemContent.self,
                                              from: Data(#"{"type":"future","description":"More\nwords"}"#.utf8))
        #expect(text(future) == "Channel updated\nMore\nwords")
    }

    private func text(_ system: ChannelSystemContent) -> String {
        ChannelSystemText.rendered(system, agents: [])
    }
}
