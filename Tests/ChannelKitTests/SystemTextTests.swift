import Foundation
import Testing
@testable import ChannelKit

struct SystemTextTests {
    @Test func systemEventsUseRenderedWordsRatherThanProtocolKinds() {
        #expect(text(.init(type: "channel_renamed", name: "Caf\u{00e9} team")) == "Channel renamed Caf\u{00e9} team")
        #expect(text(.init(type: "routine_edited", routine: .init(
            id: "r", title: "Daily review", schedule: "0 9 * * *", prompt: "blockers")))
                == "Routine edited Daily review")
        #expect(text(.init(type: "artifact_shared", actor: .user, artifact: .init(
            file: .init(kind: "session", path: "plan.md"), title: "Workshop plan")))
                == "You shared Workshop plan")
    }

    @Test func knownEventPhrasesRetainTheirValuesAndFallbacks() {
        let cases: [(ChannelSystemContent, String)] = [
            (.init(type: "tasks_completed"), "All tasks completed"),
            (.init(type: "channel_purpose_changed"), "Purpose cleared"),
            (.init(type: "channel_purpose_changed", purpose: " New\n purpose "), "Purpose updated New purpose"),
            (.init(type: "channel_directory_changed"), "Working directory cleared"),
            (.init(type: "channel_directory_changed", directory: "/a  b\nc"), "Working directory changed /a  b\nc"),
            (.init(type: "preview_changed"), "Preview cleared"),
            (.init(type: "preview_changed", preview: .init(kind: "screen", screenId: "screen")),
             "Preview updated Open screen in Toy Box"),
            (.init(type: "preview_changed", previewUrl: "/preview"), "Preview updated /preview"),
            (.init(type: "preview_changed", preview: .init(kind: "url")), "Preview updated"),
            (.init(type: "routine_scheduled"), "New routine scheduled Routine"),
            (.init(type: "routine_deleted"), "Routine deleted Routine"),
            (.init(type: "member_joined", member: .init(id: "a", name: "Ada")), "Ada joined the channel"),
            (.init(type: "member_left", member: .init(id: "a", name: "Ada")), "Ada left the channel"),
            (.init(type: "member_joined"), "Channel membership changed"),
            (.init(type: "unknown"), "Channel updated"),
        ]
        for (system, expected) in cases { #expect(text(system) == expected) }
        #expect(ChannelSystemText.phrase(for: nil) == "Channel updated")
    }

    @Test func completedTasksIgnoreRetainedUnknownDescriptions() throws {
        for raw in [
            #"{"type":"future","description":""}"#,
            #"{"type":"future","description":"Hidden server metadata\nMore words"}"#
        ] {
            var system = try JSONDecoder().decode(ChannelSystemContent.self, from: Data(raw.utf8))
            #expect(system.unknownFields?["description"]?.string != nil)
            // Known-event decoding discards extra fields. Retain a future payload through the public type setter.
            system.type = "tasks_completed"
            #expect(text(system) == "All tasks completed")
        }
    }

    @Test func groupedMembershipKeepsTheSameCountAndActionWords() throws {
        let joined = ["Ada", "Moss", "Finch"].enumerated().map {
            ChannelSystemContent(type: "member_joined", member: .init(id: "\($0.offset)", name: $0.element))
        }
        #expect(ChannelSystemText.membership([]) == nil)
        #expect(ChannelSystemText.membership([.init(type: "member_joined")]) == nil)
        #expect(ChannelSystemText.membership(Array(joined.prefix(1)))?.names == "Ada")
        #expect(ChannelSystemText.membership(Array(joined.prefix(2)))?.names == "Ada and 1 other")
        let group = try #require(ChannelSystemText.membership(joined))
        #expect(group.names == "Ada and 2 others" && group.action == "joined the channel")
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
        let future = try JSONDecoder().decode(ChannelSystemContent.self,
                                              from: Data(#"{"type":"future","description":"More\nwords"}"#.utf8))
        #expect(text(future) == "Channel updated\nMore\nwords")
    }

    private func text(_ system: ChannelSystemContent) -> String {
        ChannelSystemText.rendered(system, agents: [])
    }
}
