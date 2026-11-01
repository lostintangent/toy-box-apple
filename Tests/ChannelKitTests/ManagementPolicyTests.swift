import Foundation
import Testing
@testable import ChannelKit

struct ManagementPolicyTests {
    @Test func emptyAndOversizedMemberNamesAreRejected() {
        #expect(ChannelValidation.memberNameError(" \n ", agents: []) == "Enter an agent name.")
        #expect(ChannelValidation.memberNameError(String(repeating: "a", count: 80), agents: []) == nil)
        #expect(ChannelValidation.memberNameError(String(repeating: "a", count: 81), agents: []) != nil)
        #expect(ChannelValidation.memberNameError(String(repeating: "\u{1F680}", count: 40), agents: []) == nil)
        #expect(ChannelValidation.memberNameError(String(repeating: "\u{1F680}", count: 41), agents: []) != nil)
    }

    @Test func duplicateMentionsUseTheCanonicalHandle() {
        let agents = [ChannelAgent.lead(id: "channel"), ChannelAgent(id: "member", name: "Caf\u{00E9} Critic")]
        #expect(ChannelValidation.memberNameError(" lead ", agents: agents) != nil)
        #expect(ChannelValidation.memberNameError("CAFE-critic", agents: agents) != nil)
        #expect(ChannelValidation.memberNameError("Caf\u{00E9} Critic", agents: agents, excludingID: "member") == nil)
        #expect(ChannelValidation.memberNameError("Another critic", agents: agents) == nil)
        #expect(ChannelValidation.memberNameError("CAFE-critic", agents: [
            .init(id: "deleted", name: "Caf\u{00E9} Critic", deleted: true)
        ]) == "Another agent is already mentioned as @cafe-critic.")
    }

    @Test func editorFieldLimitsUseUTF16AndLeaveRequiredFieldPromptsToTheForm() {
        for (check, limit) in [
            (ChannelValidation.channelNameError, 100),
            (ChannelValidation.purposeError, 12_000),
            (ChannelValidation.directoryError, 4_096),
        ] {
            #expect(check("") == nil)
            #expect(check(String(repeating: "a", count: limit)) == nil)
            #expect(check(String(repeating: "a", count: limit + 1)) != nil)
            #expect(check(String(repeating: "\u{1F680}", count: limit / 2)) == nil)
            #expect(check(String(repeating: "\u{1F680}", count: limit / 2 + 1)) != nil)
        }
    }

    @Test func anExistingRoleCannotBeEmptiedButANewRoleMayBeOmitted() {
        #expect(ChannelValidation.memberRoleError("", existingRole: nil) == nil)
        #expect(ChannelValidation.memberRoleError("", existingRole: "") == "An existing role can't be emptied.")
        #expect(ChannelValidation.memberRoleError("", existingRole: "Existing") == "An existing role can't be emptied.")
        #expect(ChannelValidation.memberRoleError(String(repeating: "\u{1F680}", count: 4_000), existingRole: "Old") == nil)
        #expect(ChannelValidation.memberRoleError(String(repeating: "a", count: 8_001), existingRole: nil)
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

    @Test func theWorkInProgressFilterKeepsMatchingTasksAndTheirMatchingChildren() {
        let tasks: [ChannelTask] = [
            .init(id: "a", title: "A", status: "blocked", children: [
                .init(id: "b", title: "B", children: [
                    .init(id: "c", title: "C", status: "in_progress"),
                    .init(id: "d", title: "D"),
                ]),
                .init(id: "e", title: "E", status: "done"),
            ]),
            .init(id: "f", title: "F", status: "done", children: [.init(id: "g", title: "G")]),
            .init(id: "h", title: "H", children: [.init(id: "i", title: "I", status: "in_progress")]),
        ]
        let filtered = channelTasksHoldingWorkInProgress(tasks)
        #expect(filtered.map(\.id) == ["a", "h"])
        #expect(filtered[0].children?.map(\.id) == ["b"])
        #expect(filtered[0].children?[0].children?.map(\.id) == ["c"])
        #expect(filtered[0].children?[0].children?[0].children == nil)
        #expect(filtered[1].children?.map(\.id) == ["i"])
    }
}
