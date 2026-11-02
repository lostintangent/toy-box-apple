import Foundation
import Testing
@testable import ChannelKit

struct ManagementPolicyTests {
    @Test func emptyAndOversizedMemberNamesAreRejected() {
        #expect(ChannelAgent.nameError(" \n ", agents: []) == "Enter an agent name.")
        #expect(ChannelAgent.nameError(String(repeating: "a", count: 80), agents: []) == nil)
        #expect(ChannelAgent.nameError(String(repeating: "a", count: 81), agents: []) != nil)
        #expect(ChannelAgent.nameError(String(repeating: "\u{1F680}", count: 40), agents: []) == nil)
        #expect(ChannelAgent.nameError(String(repeating: "\u{1F680}", count: 41), agents: []) != nil)
    }

    @Test func duplicateMentionsUseTheCanonicalHandle() {
        let agents = [ChannelAgent.lead(id: "channel"), ChannelAgent(id: "member", name: "Caf\u{00E9} Critic")]
        #expect(ChannelAgent.nameError(" lead ", agents: agents) != nil)
        #expect(ChannelAgent.nameError("CAFE-critic", agents: agents) != nil)
        #expect(ChannelAgent.nameError("Caf\u{00E9} Critic", agents: agents, excludingID: "member") == nil)
        #expect(ChannelAgent.nameError("Another critic", agents: agents) == nil)
        #expect(ChannelAgent.nameError("CAFE-critic", agents: [
            .init(id: "deleted", name: "Caf\u{00E9} Critic", deleted: true)
        ]) == "Another agent is already mentioned as @cafe-critic.")
    }

    @Test func editorFieldLimitsUseUTF16AndLeaveRequiredFieldPromptsToTheForm() {
        for (check, limit) in [
            (Channel.nameError, 100),
            (Channel.purposeError, 12_000),
            (Channel.directoryError, 4_096),
        ] {
            #expect(check("") == nil)
            #expect(check(String(repeating: "a", count: limit)) == nil)
            #expect(check(String(repeating: "a", count: limit + 1)) != nil)
            #expect(check(String(repeating: "\u{1F680}", count: limit / 2)) == nil)
            #expect(check(String(repeating: "\u{1F680}", count: limit / 2 + 1)) != nil)
        }
    }

    @Test func anExistingRoleCannotBeEmptiedButANewRoleMayBeOmitted() {
        #expect(ChannelAgent.roleError("", existingRole: nil) == nil)
        #expect(ChannelAgent.roleError("", existingRole: "") == "An existing role can't be emptied.")
        #expect(ChannelAgent.roleError("", existingRole: "Existing") == "An existing role can't be emptied.")
        #expect(ChannelAgent.roleError(String(repeating: "\u{1F680}", count: 4_000), existingRole: "Old") == nil)
        #expect(ChannelAgent.roleError(String(repeating: "a", count: 8_001), existingRole: nil)
                == "Roles are limited to 8,000 characters.")
    }

    @Test func taskStatusDeterminesInitialDisclosureAndSubtaskProgress() {
        func task(_ status: String, childStatus: String = "pending", hasChildren: Bool = true) -> ChannelTask {
            .init(id: "task", title: "Task", status: status,
                  children: hasChildren ? [.init(id: "child", title: "Child", status: childStatus)] : nil)
        }
        for status in ["pending", "blocked", "done"] { #expect(!task(status).isExpandedByDefault) }
        #expect(task("in_progress").isExpandedByDefault)
        for status in ["pending", "blocked", "done"] {
            #expect(task(status, childStatus: "in_progress").isExpandedByDefault)
        }
        for status in ["pending", "in_progress", "blocked", "done"] { #expect(task(status).showsChildProgress) }
        #expect(!task("in_progress", hasChildren: false).showsChildProgress)
        #expect(!task("done", hasChildren: false).showsChildProgress)
        #expect(!task("future").isExpandedByDefault && task("future").showsChildProgress)
        #expect(task("future").statusDescription == "pending")
    }

    @Test func workInProgressAnywhereBelowAParentExpandsIt() {
        let parent = ChannelTask(id: "a", title: "A", status: "blocked", children: [
            .init(id: "b", title: "B", children: [.init(id: "c", title: "C", status: "in_progress")]),
        ])
        #expect(parent.holdsWorkInProgress && parent.isExpandedByDefault)
        #expect(parent.children?.first?.isExpandedByDefault == true)
        let finished = ChannelTask(id: "f", title: "F", status: "done", children: [.init(id: "g", title: "G")])
        #expect(!finished.holdsWorkInProgress && !finished.isExpandedByDefault)
    }

    @Test func theWorkInProgressFilterKeepsEachKeptTaskWhole() {
        let tasks: [ChannelTask] = [
            .init(id: "a", title: "A", status: "blocked", children: [
                .init(id: "b", title: "B", children: [
                    .init(id: "c", title: "C", status: "in_progress"),
                    .init(id: "d", title: "D", diff: .init(added: 4, removed: 1)),
                ]),
                .init(id: "e", title: "E", status: "done", diff: .init(added: 2, removed: 0)),
            ]),
            .init(id: "f", title: "F", status: "done", children: [.init(id: "g", title: "G")]),
            .init(id: "h", title: "H", children: [.init(id: "i", title: "I", status: "in_progress")]),
            .init(id: "j", title: "J", status: "in_progress", children: [.init(id: "k", title: "K")]),
        ]
        let roots = tasks.holdingWorkInProgress
        #expect(roots.map(\.id) == ["a", "h", "j"])
        #expect(roots[0] == tasks[0])
        #expect([roots[0]].diff == .init(added: 6, removed: 1))
        #expect((roots[0].children ?? []).holdingWorkInProgress.map(\.id) == ["b"])
        #expect((roots[0].children?[0].children ?? []).holdingWorkInProgress.map(\.id) == ["c"])
        #expect((roots[1].children ?? []).holdingWorkInProgress.map(\.id) == ["i"])
        #expect((roots[2].children ?? []).holdingWorkInProgress.isEmpty)
        #expect(roots[2].showsChildProgress)
        #expect([tasks[1]].holdingWorkInProgress.isEmpty)
    }
}
