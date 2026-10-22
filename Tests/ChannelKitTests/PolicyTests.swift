import Foundation
import Testing
@testable import ChannelKit

struct PolicyTests {
    let lead = ChannelAgent.lead(id: "lead")
    let ada = ChannelAgent(id: "ada", name: "Ada")
    let finch = ChannelAgent(id: "finch", name: "Finch")

    @Test func mentionGrammar() {
        #expect(agentHandleFromName("  Déjà Vu! ") == "deja-vu")
        #expect(agentHandleFromName("Everyone") == "everyone-agent")
        #expect(agentHandleFromName("!!!") == "teammate")
        #expect(agentHandleFromName(String(repeating: "x", count: 60)).count == 48)
        let mentions = extractAgentMentionHandles("dev@example.com and @ADA, (@finch) @ada @everyone")
        #expect(mentions.handles == ["ada", "finch"])
        #expect(mentions.mentionAll)
        #expect(extractAgentMentionHandles("name-@ada 9@finch").handles.isEmpty)
        #expect(extractAgentMentionHandles("@Kit @İris").handles.isEmpty)
        #expect(withoutLeadingMentions("@Ada, @Finch: Ship it", agents: [ada, finch]) == "Ship it")
        #expect(withoutLeadingMentions("@Ada @unknown Ship it", agents: [ada]) == "@Ada @unknown Ship it")
        #expect(withoutLeadingMentions("@Ada", agents: [ada]) == "@Ada")
        #expect(splitAgentMentionText("Hello @Ada!").map(\.content) == ["Hello ", "@Ada", "!"])
    }

    @Test func canonicalAudience() {
        let members = [ada, finch]
        func ids(_ text: String, sender: ChannelMessageSender = .user,
                 acknowledged: Bool = false) -> [String] {
            resolveChannelAudience(content: text, sender: sender, lead: lead, members: members,
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
        #expect(channelAudienceLabel([lead, ada], reachableCount: 2) == "Everyone")
    }

    @Test func taskMathPreservesMeasuredZero() {
        let tasks = [
            ChannelTask(id: "parent", title: "Build", status: "in_progress",
                        diff: .init(added: 4, removed: 2),
                        children: [.init(id: "child", title: "Review", status: "done",
                                         ownerId: "ada", diff: .init(added: 3, removed: 1))]),
            ChannelTask(id: "zero", title: "Measure", status: "done", diff: .init(added: 0, removed: 0)),
        ]
        #expect(channelTasksDiff(tasks) == .init(added: 7, removed: 3))
        #expect(channelTasksDiff([]) == nil)
        #expect(channelTasksDiff([tasks[1]]) == .init(added: 0, removed: 0))
        #expect(channelTasksProgress(tasks) == .init(done: 1, total: 2))
        #expect(!channelTasksComplete(tasks))
        #expect(!channelTasksComplete([]))
        #expect(channelTasksComplete([.init(id: "done", title: "Done", status: "done")]))
        #expect(unassignChannelTasks(tasks, agentId: "ada")[0].children?[0].ownerId == nil)
    }

    @Test func attentionAndPresence() {
        var channel = Channel(id: "test", name: "Test", model: .init(provider: "test", name: "test"),
                              latestSequence: 10, seenThrough: 4, completedSequence: 7,
                              requestSequence: 8, updatedAt: "2026-10-01T00:00:00Z")
        #expect(channelSidebarStatus(channel, isOpen: true) == .waiting)
        channel.requestSequence = nil
        #expect(channelStatus(channel) == .finished)
        #expect(channelSidebarStatus(channel, isOpen: true) == nil)
        channel.seenThrough = 7
        #expect(channelStatus(channel) == .unread)
        channel.seenThrough = 10
        #expect(channelStatus(channel) == nil)
        var agent = ada
        agent.status = .init(state: "waiting", text: "Waiting", wakeAt: "2026-10-02T00:00:00Z")
        #expect(channelAgentPresence(agent, running: true) == .init(state: "working"))
        #expect(channelAgentPresence(agent, running: false) == agent.status)
        agent.status = .init(state: "working", text: "Settling")
        #expect(channelAgentPresence(agent, running: false) == .init(state: "idle"))
        #expect(channelAgentIdentity([ada], id: "removed").name == "Deleted agent")
    }
}
