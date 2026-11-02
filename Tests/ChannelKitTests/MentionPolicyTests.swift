import Foundation
import Testing
@testable import ChannelKit

struct MentionPolicyTests {
    @Test func mentionContextUsesCaretAndCanonicalBoundaries() {
        let text = "Hello, @Pi"
        let context = AgentMentions.Query.match(text: text, selection: .init(location: text.utf16.count, length: 0))
        #expect(context?.text == "pi")
        #expect(context?.range == NSRange(location: 7, length: 3))
        #expect(AgentMentions.Query.match(text: "a@pixel", selection: .init(location: 7, length: 0)) == nil)
        #expect(AgentMentions.Query.match(text: "@pi", selection: .init(location: 3, length: 1)) == nil)
        #expect(AgentMentions.Query.match(text: "@pi", selection: .init(location: NSNotFound, length: 0)) == nil)
        #expect(AgentMentions.Query.match(text: "@\n", selection: .init(location: 2, length: 0)) == nil)
        let emoji = "\u{1f642} @pi"
        #expect(AgentMentions.Query.match(text: emoji, selection: .init(location: emoji.utf16.count, length: 0))?.range
                == NSRange(location: 3, length: 3))
        #expect(AgentMentions.Query.match(text: "@pi rest", selection: .init(location: 3, length: 0))?.text == "pi")
        #expect(AgentMentions.Query.match(text: "@pi", selection: .init(location: -1, length: 0)) == nil)
    }

    @Test func completionUsesCanonicalMatchingOrderAndCreateRules() {
        let agents: [ChannelAgent] = [
            .lead(id: "lead"),
            .init(id: "z", name: "Zebra", role: "Design"),
            .init(id: "a", name: "Ada", role: "Engineering"),
            .init(id: "p", name: "Pixel", role: "Design"),
        ]
        #expect(AgentMentions.Choice.choices(matching: "", among: agents).map(\.name)
                == ["Everyone", "Lead", "Ada", "Pixel", "Zebra"])
        #expect(AgentMentions.Choice.choices(matching: "design", among: agents).filter { !$0.isCreate }.map(\.name)
                == ["Pixel", "Zebra"])
        #expect(AgentMentions.Choice.choices(matching: "pixel", among: agents).allSatisfy { !$0.isCreate })
        let create = AgentMentions.Choice.choices(matching: "new-person", among: agents).last
        #expect(create?.isCreate == true)
        #expect(create?.name == "New Person")
        let member = AgentMentions.Choice.choices(matching: "ada", among: agents).first
        #expect(member?.isMember == true && member?.agent == agents[2])
        let lead = AgentMentions.Choice.choices(matching: "lead", among: agents).first
        #expect(lead?.isMember == false && lead?.agent == agents[0])
        #expect(AgentMentions.Choice.choices(matching: "new-person", among: agents, allowsCreation: false).isEmpty)
    }

    @Test func deletedAgentsNeverAppearButTheOriginalLeadStillDeterminesMembership() {
        let agents: [ChannelAgent] = [
            .init(id: "lead", name: "Lead", deleted: true),
            .init(id: "a", name: "Ada"),
        ]
        let choices = AgentMentions.Choice.choices(matching: "", among: agents)
        #expect(choices.map(\.name) == ["Everyone", "Ada"])
        #expect(choices.last?.isMember == true)
        #expect(choices.last?.detail == "Onboarding")
        #expect(choices.last?.handle == "@ada")
    }

    @Test func wholeMentionsUseTheTranscriptBoundaries() {
        let text = "@Ada, @Adam, x@Ada, @Ada-bot and @Ada's"
        let ranges = AgentMentions.ranges(of: "@Ada", in: text)
        #expect(ranges.map { String(text[$0.upperBound...].prefix(2)) } == [", ", "'s"])
        #expect(AgentMentions.ranges(of: "", in: text).isEmpty)
        #expect(AgentMentions.ranges(of: "@ada", in: text).isEmpty)
        let adjacent = "\u{00e9}@Ada \u{1f642}@Ada 9@Ada -@Ada @Ada9"
        #expect(AgentMentions.ranges(of: "@Ada", in: adjacent).count == 2)
    }
}
