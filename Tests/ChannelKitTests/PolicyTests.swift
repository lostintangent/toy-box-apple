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
        #expect(agentHandleFromName("--Ada  Lovelace__2--") == "ada-lovelace-2")
        #expect(agentHandleFromName("ÅNGSTRÖM ﬁx") == "angstrom-fix")
        #expect(agentHandleFromName("日本 Team") == "team")
        #expect(agentHandleFromName(String(repeating: "x", count: 47) + " y") == String(repeating: "x", count: 47))
        let mentions = extractAgentMentionHandles("dev@example.com and @ADA, (@finch) @ada @everyone")
        #expect(mentions.handles == ["ada", "finch"])
        #expect(mentions.mentionAll)
        #expect(extractAgentMentionHandles("name-@ada 9@finch").handles.isEmpty)
        #expect(extractAgentMentionHandles("@Kit @İris").handles.isEmpty)
        #expect(withoutLeadingMentions("@Ada, @Finch: Ship it", agents: [ada, finch]) == "Ship it")
        #expect(withoutLeadingMentions("@Ada @unknown Ship it", agents: [ada]) == "@Ada @unknown Ship it")
        #expect(withoutLeadingMentions("@Ada", agents: [ada]) == "@Ada")
    }

    @Test func mentionCompletionIncludesEveryAgentForAnEmptyQuery() {
        let engineer = ChannelAgent(id: "ada", name: "Ada Lovelace", role: "Swift engineer")
        #expect(agentMatchesMentionQuery(lead, query: ""))
        #expect(agentMatchesMentionQuery(ada, query: ""))
        #expect(agentMatchesMentionQuery(engineer, query: ""))
        #expect(agentMatchesMentionQuery(engineer, query: "LOVELACE"))
        #expect(agentMatchesMentionQuery(engineer, query: "ada-lovelace"))
        #expect(agentMatchesMentionQuery(engineer, query: "ENGINEER"))
        #expect(!agentMatchesMentionQuery(engineer, query: "unknown"))
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
        #expect(unassignChannelTasks(tasks, agentId: "ada")[0].children?[0].ownerId == nil)
    }

    @Test func taskTimingFloorsElapsedCeilsCheckInAndHandlesAbsentOrInvalidDates() throws {
        let now = try #require(ChannelDates.date("2026-10-24T11:26:59Z"))
        var task = ChannelTask(id: "task", title: "Task", status: "in_progress",
                               startedAt: "2026-10-24T10:00:00Z", checkInAt: "2026-10-24T11:57:00Z")
        #expect(channelTaskTiming(task, now: now) == .init(elapsedMinutes: 86, checkInMinutes: 31))
        #expect(channelTaskTiming(task, now: now.addingTimeInterval(1))
                == .init(elapsedMinutes: 87, checkInMinutes: 30))
        task.checkInAt = "2026-10-24T11:26:59Z"
        #expect(channelTaskTiming(task, now: now)?.checkInMinutes == 0)
        task.checkInAt = "2026-10-24T11:00:00Z"
        #expect(channelTaskTiming(task, now: now)?.checkInMinutes == 0)
        for status in ["pending", "blocked", "done"] {
            task.status = status
            #expect(channelTaskTiming(task, now: now) == .init(elapsedMinutes: 86))
        }
        task.status = "in_progress"
        task.checkInAt = "invalid"
        #expect(channelTaskTiming(task, now: now) == .init(elapsedMinutes: 86))
        task.startedAt = "2026-10-24T12:00:00Z"
        #expect(channelTaskTiming(task, now: now)?.elapsedMinutes == 0)
        task.startedAt = "invalid"
        #expect(channelTaskTiming(task, now: now) == nil)
        task.checkInAt = "2026-10-24T12:00:00Z"
        task.startedAt = nil
        #expect(channelTaskTiming(task, now: now) == nil)
    }

    @Test func artifactsAreNewestFirstWithStableTiesAndUndatedItemsLast() {
        func artifact(_ id: String, sharedAt: String? = nil) -> ChannelArtifact {
            ChannelArtifact(id: id, file: .init(kind: "machine", path: "/\(id)"), title: id, sharedAt: sharedAt)
        }
        let artifacts = [
            artifact("undated"),
            artifact("older", sharedAt: "2026-10-24T08:00:00Z"),
            artifact("newer", sharedAt: "2026-10-24T11:00:00+02:00"),
            artifact("same-time", sharedAt: "2026-10-24T09:00:00.000Z"),
            artifact("invalid", sharedAt: "not-a-date")
        ]
        #expect(channelArtifactsNewestFirst(artifacts).map(\.id)
                == ["newer", "same-time", "older", "undated", "invalid"])
        #expect(channelArtifactsNewestFirst([]).isEmpty)
    }

    @Test func artifactTiesStayInInputOrderAcrossSortRuns() {
        let timestamps: [String?] = [
            nil, "invalid", "2026-10-24T09:00:00Z", "2026-10-24T11:00:00+02:00",
            "2026-10-25T09:00:00Z"
        ]
        let artifacts = (0..<128).map { index in
            ChannelArtifact(file: .init(kind: "machine", path: "/\(index)"), title: "\(index)",
                            sharedAt: timestamps[index % timestamps.count])
        }
        let newest = artifacts.filter { $0.sharedAt == timestamps[4] }
        let tied = artifacts.filter { $0.sharedAt == timestamps[2] || $0.sharedAt == timestamps[3] }
        let undated = artifacts.filter { $0.sharedAt == nil || $0.sharedAt == "invalid" }
        #expect(channelArtifactsNewestFirst(artifacts) == newest + tied + undated)
    }

    @Test func wireDatesAcceptOptionalFractionsAndOffsets() throws {
        let whole = Date(timeIntervalSince1970: 1_792_832_400)
        for (value, fraction) in [
            ("2026-10-24T09:00:00Z", 0.0),
            ("2026-10-24T09:00:00.000Z", 0.0),
            ("2026-10-24T09:00:00.125Z", 0.125),
            ("2026-10-24T09:00:00.123456Z", 0.123456),
            ("2026-10-24T09:00:00.123456789Z", 0.123456789),
            ("2026-10-24T11:00:00+02:00", 0.0),
            ("2026-10-24T03:30:00.125-05:30", 0.125),
        ] {
            let date = try #require(ChannelDates.date(value))
            #expect(abs(date.timeIntervalSince(whole) - fraction) < 0.000001, Comment(rawValue: value))
        }
        for value in ["", "not-a-date", "2026-10-24T09:00:00.invalidZ"] {
            #expect(ChannelDates.date(value) == nil)
        }
    }

    @Test func attentionAndIdentity() {
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
        #expect(channelAgentIdentity([ada], id: "removed").name == "Deleted agent")
    }

    @Test func activityReactionsRequireWorkingPresenceAndDurableTargets() {
        var agent = ada
        agent.status = .init(state: "working", text: "Reviewing", lookingAt: 12, workingOn: 12)
        let message = ChannelMessage(id: "m12", sequence: 12, timestamp: "2026-10-01T00:00:00Z",
                                     sender: .user, content: .text("Review this"),
                                     reactions: [.init(agentId: "finch", reaction: "agree")])
        let working = channelStatusReactions(agents: [agent], presence: ["ada": .init(state: "working")])
        #expect(channelMessageReactions(message, status: working).map(\.reaction) == ["agree", "looking", "working"])
        let absent = channelStatusReactions(agents: [agent], presence: [:])
        #expect(channelMessageReactions(message, status: absent).map(\.reaction) == ["agree"])
        agent.status = .init(state: "waiting", text: "Waiting", lookingAt: 12)
        let waiting = channelStatusReactions(agents: [agent], presence: ["ada": .init(state: "working")])
        #expect(channelMessageReactions(message, status: waiting).map(\.reaction) == ["agree"])
    }

    @Test func statusReactionsGroupBySequenceInAgentOrder() {
        var ada = ada
        var finch = finch
        ada.status = .init(state: "working", text: "Reviewing", lookingAt: 12, workingOn: 14)
        finch.status = .init(state: "working", text: "Building", lookingAt: 14, workingOn: 14)
        let presence: [String: ChannelAgentPresence] = ["ada": .init(state: "working"), "finch": .init(state: "working")]
        let reactions = channelStatusReactions(agents: [ada, finch], presence: presence)
        #expect(reactions[12]?.map(\.agentId) == ["ada"])
        #expect(reactions[14]?.map { "\($0.agentId) \($0.reaction)" } == ["ada working", "finch looking", "finch working"])
        #expect(channelStatusReactions(agents: [ada, finch], presence: [:]).isEmpty)
        let message = ChannelMessage(id: "m14", sequence: 14, timestamp: "2026-10-22T17:23:00.000Z",
                                     sender: .user, content: .text("Ship it"),
                                     reactions: [.init(agentId: "lead", reaction: "done")])
        #expect(channelMessageReactions(message, status: reactions).map { "\($0.agentId) \($0.reaction)" }
                == ["lead done", "ada working", "finch looking", "finch working"])
    }
}
