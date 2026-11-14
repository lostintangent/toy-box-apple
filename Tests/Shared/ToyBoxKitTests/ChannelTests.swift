import Foundation
import Testing
@testable import ChannelKit

struct ChannelTests {
    let ada = ChannelAgent(id: "ada", name: "Ada")

    @Test func purposePreviewKeepsTheOriginalFirstLineSemantics() {
        func preview(_ purpose: String?) -> String? {
            Channel(id: "c", name: "C", purpose: purpose, model: .init(provider: "p", name: "m"),
                    updatedAt: "2026-10-01T00:00:00Z").purposePreview
        }
        #expect(preview("  Ship the demo  \nThen the docs") == "Ship the demo")
        #expect(preview("\n\nFirst\r\nSecond") == "First")
        #expect(preview(" \nSecond") == nil)
        #expect(preview("") == nil)
        #expect(preview(nil) == nil)
    }

    @Test func attentionAndIdentity() {
        var channel = Channel(id: "test", name: "Test", model: .init(provider: "test", name: "test"),
                              latestSequence: 10, seenThrough: 4, completedSequence: 7,
                              requestSequence: 8, updatedAt: "2026-10-01T00:00:00Z")
        #expect(channel.sidebarAttention(isOpen: true) == .waiting)
        channel.requestSequence = nil
        #expect(channel.attention == .finished)
        #expect(channel.sidebarAttention(isOpen: true) == nil)
        channel.seenThrough = 7
        #expect(channel.attention == .unread)
        channel.seenThrough = 10
        #expect(channel.attention == nil)
        #expect(ChannelAgent(id: "removed", in: [ada]).name == "Deleted agent")
    }

    @Test func anAvatarDecodesAsAMarkOrAnImageAndIsAbsentWhenNeverSet() throws {
        func channel(_ avatar: String) throws -> Channel {
            try JSONDecoder().decode(Channel.self, from: Data("""
            {"id":"c","name":"C","model":{"provider":"p","name":"m"},"latestSequence":4,"seenThrough":4,
             "completedSequence":null,"requestSequence":null,"updatedAt":"2026-10-01T00:00:00Z"\(avatar)}
            """.utf8))
        }
        let image = ChannelAvatar.image("/api/serve/machine/channels/c/avatar-0123.png")
        let marked = try channel(##","avatar":{"mark":"M4 12H20","color":"#123456"}"##)
        #expect(marked.avatar == .mark(.init(mark: "M4 12H20", color: "#123456")))
        #expect(try channel(#","avatar":{"image":"/api/serve/machine/channels/c/avatar-0123.png"}"#).avatar == image)
        #expect(try channel("").avatar == nil)
        #expect(try JSONDecoder().decode(Channel.self, from: JSONEncoder().encode(marked)) == marked)
    }

    @Test func anAvatarChangeSetsTheChannelsAvatarAsARenameSetsItsName() throws {
        let url = try #require(Bundle.module.url(forResource: "channel-snapshot", withExtension: "json",
                                                subdirectory: "Fixtures"))
        var state = try JSONDecoder().decode(ChannelState.self, from: Data(contentsOf: url))
        state.channel.seenThrough = state.channel.latestSequence
        let sequence = state.channel.latestSequence + 1
        let message = try JSONDecoder().decode(ChannelMessage.self, from: Data("""
            {"id":"avatar","sequence":\(sequence),"timestamp":"2026-11-12T05:30:00.000Z","sender":{"type":"system"},
             "content":{"type":"channel_avatar_changed","actor":{"type":"agent","agentId":"lead"},
                        "avatar":{"image":"/api/serve/machine/channels/c/avatar-0123.png"}}}
            """.utf8))
        let system = try #require(message.system)
        #expect(system.actor == .agent("lead"))
        #expect(system.avatar == .image("/api/serve/machine/channels/c/avatar-0123.png"))
        #expect(try JSONDecoder().decode(ChannelMessage.self, from: JSONEncoder().encode(message)) == message)

        let next = state.applying(.init(type: "message", revision: state.revision + 1, message: message))
        #expect(next.channel.avatar == system.avatar)
        #expect(next.channel.updatedAt == message.timestamp)
        #expect(next.channel.unreadAfter == sequence - 1)
        let missing = Data(#"{"type":"channel_avatar_changed","actor":{"type":"user"}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ChannelSystemContent.self, from: missing) }
    }

    /// Mirrors Toy Box 0.4.5's `reduceChannel`, which moves the server's read position the same way.
    @Test func yourMessageReadsTheChannelThroughItselfAndClearsACompletion() throws {
        let url = try #require(Bundle.module.url(forResource: "channel-snapshot", withExtension: "json",
                                                subdirectory: "Fixtures"))
        var state = try JSONDecoder().decode(ChannelState.self, from: Data(contentsOf: url))
        func post(_ sender: String) throws {
            let sequence = state.channel.latestSequence + 1
            let message = try JSONDecoder().decode(ChannelMessage.self, from: Data("""
                {"id":"m\(sequence)","sequence":\(sequence),"timestamp":"2026-11-12T05:30:00.000Z",
                 "sender":\(sender),"content":"Found a regression."}
                """.utf8))
            state = state.applying(.init(type: "message", revision: state.revision + 1, message: message))
        }

        try post(#"{"type":"agent","agentId":"\#(state.lead.id)"}"#)
        state.channel.requestSequence = nil
        state.channel.completedSequence = state.channel.latestSequence
        #expect(state.channel.attention == .finished)
        try post(#"{"type":"user"}"#)
        #expect(state.channel.seenThrough == state.channel.latestSequence)
        #expect(state.channel.attention == nil)
    }

    @Test func folderNamesUseTheLastComponentAndPreserveRootAndEmptyPaths() {
        #expect(Channel.folderName(of: "/srv/work/toy-box") == "toy-box")
        #expect(Channel.folderName(of: "/srv/work/toy-box/") == "toy-box")
        #expect(Channel.folderName(of: "/") == "/")
        #expect(Channel.folderName(of: "") == "")
    }
}
