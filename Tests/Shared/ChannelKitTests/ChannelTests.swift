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
}
