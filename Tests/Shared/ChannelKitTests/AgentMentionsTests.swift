import Foundation
import Testing
@testable import ChannelKit

struct AgentMentionsTests {
    let lead = ChannelAgent.lead(id: "lead")
    let ada = ChannelAgent(id: "ada", name: "Ada")
    let finch = ChannelAgent(id: "finch", name: "Finch")

    @Test func mentionGrammar() {
        #expect(ChannelAgent.handle(forName: "  Déjà Vu! ") == "deja-vu")
        #expect(ChannelAgent.handle(forName: "Everyone") == "everyone-agent")
        #expect(ChannelAgent.handle(forName: "!!!") == "teammate")
        #expect(ChannelAgent.handle(forName: String(repeating: "x", count: 60)).count == 48)
        #expect(ChannelAgent.handle(forName: "--Ada  Lovelace__2--") == "ada-lovelace-2")
        #expect(ChannelAgent.handle(forName: "ÅNGSTRÖM ﬁx") == "angstrom-fix")
        #expect(ChannelAgent.handle(forName: "日本 Team") == "team")
        #expect(ChannelAgent.handle(forName: String(repeating: "x", count: 47) + " y") == String(repeating: "x", count: 47))
        let mentions = AgentMentions(parsing: "dev@example.com and @ADA, (@finch) @ada @everyone")
        #expect(mentions.handles == ["ada", "finch"])
        #expect(mentions.mentionAll)
        #expect(AgentMentions(parsing: "name-@ada 9@finch").handles.isEmpty)
        #expect(AgentMentions(parsing: "@\u{212A}it @\u{0130}ris").handles.isEmpty)
        #expect(AgentMentions.removingLeadingMentions(from: "@Ada, @Finch: Ship it", agents: [ada, finch]) == "Ship it")
        #expect(AgentMentions.removingLeadingMentions(from: "@Ada @unknown Ship it", agents: [ada]) == "@Ada @unknown Ship it")
        #expect(AgentMentions.removingLeadingMentions(from: "@Ada", agents: [ada]) == "@Ada")
    }

    @Test func mentionCompletionIncludesEveryAgentForAnEmptyQuery() {
        let engineer = ChannelAgent(id: "ada", name: "Ada Lovelace", role: "Swift engineer")
        #expect(lead.matches(mentionQuery: ""))
        #expect(ada.matches(mentionQuery: ""))
        #expect(engineer.matches(mentionQuery: ""))
        #expect(engineer.matches(mentionQuery: "LOVELACE"))
        #expect(engineer.matches(mentionQuery: "ada-lovelace"))
        #expect(!engineer.matches(mentionQuery: "ENGINEER"), "A role never matches")
        #expect(!engineer.matches(mentionQuery: "unknown"))
        let reviewer = ChannelAgent(id: "moss", name: "Moss", role: "Works with Pixel")
        #expect(!reviewer.matches(mentionQuery: "pix"), "Nor does another agent its role names")
        #expect(reviewer.matches(mentionQuery: "mo"))
    }

    @Test func canonicalAudience() {
        let members = [ada, finch]
        func ids(_ text: String, sender: ChannelMessageSender = .user,
                 acknowledged: Bool = false) -> [String] {
            AgentMentions(parsing: text).audience(sender: sender, lead: lead, members: members,
                                                  acknowledgedRequest: acknowledged).map(\.id)
        }
        #expect(ids("Hello") == ["lead"])
        #expect(ids("Hello", sender: .agent("lead")).isEmpty)
        #expect(ids("Hello", sender: .agent("ada")) == ["lead"])
        #expect(ids("@Ada hello") == ["ada"])
        #expect(ids("@unknown hello").isEmpty)
        #expect(ids("@Ada hello", acknowledged: true) == ["lead", "ada"])
        #expect(ids("@everyone", sender: .agent("ada")) == ["lead", "finch"])
        #expect(ids("@ada", sender: .agent("ada")).isEmpty)
        #expect(AgentMentions.audienceLabel(for: [lead, ada], reachableCount: 2) == "Everyone")
    }

    @Test func mentionQueryUsesCaretAndCanonicalBoundaries() {
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
        #expect(AgentMentions.Choice.choices(matching: "a", among: agents).filter { !$0.isCreate }.map(\.name)
                == ["Lead", "Ada", "Zebra"])
        #expect(AgentMentions.Choice.choices(matching: "design", among: agents).allSatisfy { $0.isCreate })
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
