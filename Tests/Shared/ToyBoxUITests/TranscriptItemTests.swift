import ToyBoxKit
import Foundation
import Testing
import ToyBoxUI

@Suite("Transcript items")
struct TranscriptItemTests {
    @Test func runsSplitIntoEntriesThatEachMarkTheirOwnSequence() {
        let lead = ChannelAgent(id: "lead", name: "Lead")
        let ada = ChannelAgent(id: "ada", name: "Ada")
        let messages = [(1, ChannelMessageSender.user), (2, .agent("lead")), (3, .agent("lead")), (4, .agent("ada"))]
            .map { sequence, sender in
                ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-25T12:00:00Z",
                               sender: sender, content: .text("Message \(sequence)"))
            }
        let rows = TranscriptRowBuilder().rows(messages, lead: lead, members: [ada], unreadAfter: 3,
                                               calendar: Calendar(identifier: .gregorian))
        let items = TranscriptItem.items(rows)

        #expect(items.map(\.id) == ["m1", "m2", "m3", "m4"])
        #expect(items.map(\.order) == [0, 1, 2, 3])
        #expect(items.map(\.sequence) == [1, 2, 3, 4])
        #expect(items.map(\.spacing) == [0, TranscriptSpacing.run, TranscriptSpacing.entry, TranscriptSpacing.divider])
        guard case .agent(_, _, let firstStarts) = items[1].content,
              case .agent(_, _, let secondStarts) = items[2].content else {
            Issue.record("Lead's run should become two agent entries.")
            return
        }
        #expect(firstStarts && !secondStarts)
        // A run's divider is drawn once, above its first entry.
        #expect(items[2].divider == nil)
        #expect(items[3].divider?.unread == true)
    }
}
