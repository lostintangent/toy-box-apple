import Foundation
import Testing
@testable import ChannelKit

struct ChannelTaskTests {
    @Test func taskMathPreservesMeasuredZero() {
        let tasks = [
            ChannelTask(id: "parent", title: "Build", status: "in_progress",
                        diff: .init(added: 4, removed: 2),
                        children: [.init(id: "child", title: "Review", status: "done",
                                         ownerId: "ada", diff: .init(added: 3, removed: 1))]),
            ChannelTask(id: "zero", title: "Measure", status: "done", diff: .init(added: 0, removed: 0)),
        ]
        #expect(tasks.diff == .init(added: 7, removed: 3))
        #expect(([] as [ChannelTask]).diff == nil)
        #expect([tasks[1]].diff == .init(added: 0, removed: 0))
        #expect(tasks.progress == .init(done: 1, total: 2))
        #expect(tasks.unassigning(agentId: "ada")[0].children?[0].ownerId == nil)
    }

    @Test func taskTimingFloorsElapsedCeilsCheckInAndHandlesAbsentOrInvalidDates() throws {
        let now = try #require(try? Date("2026-10-24T11:26:59Z", strategy: .iso8601))
        var task = ChannelTask(id: "task", title: "Task", status: "in_progress",
                               startedAt: "2026-10-24T10:00:00Z", checkInAt: "2026-10-24T11:57:00Z")
        #expect(task.timing(now: now) == .init(elapsedMinutes: 86, checkInMinutes: 31))
        #expect(task.timing(now: now.addingTimeInterval(1))
                == .init(elapsedMinutes: 87, checkInMinutes: 30))
        task.checkInAt = "2026-10-24T11:26:59Z"
        #expect(task.timing(now: now)?.checkInMinutes == 0)
        task.checkInAt = "2026-10-24T11:00:00Z"
        #expect(task.timing(now: now)?.checkInMinutes == 0)
        for status in ["pending", "blocked", "done"] {
            task.status = status
            #expect(task.timing(now: now) == .init(elapsedMinutes: 86))
        }
        task.status = "in_progress"
        task.checkInAt = "invalid"
        #expect(task.timing(now: now) == .init(elapsedMinutes: 86))
        task.startedAt = "2026-10-24T12:00:00Z"
        #expect(task.timing(now: now)?.elapsedMinutes == 0)
        task.startedAt = "invalid"
        #expect(task.timing(now: now) == nil)
        task.checkInAt = "2026-10-24T12:00:00Z"
        task.startedAt = nil
        #expect(task.timing(now: now) == nil)
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

    @Test func aDisclosureToggleHoldsUntilItsTasksDefaultChanges() throws {
        func tree(_ status: String) -> ChannelTask {
            .init(id: "parent", title: "Parent", status: status, children: [
                .init(id: "nested", title: "Nested", status: "blocked", children: [.init(id: "leaf", title: "Leaf")]),
            ])
        }
        let active = tree("in_progress")
        let nested = try #require(active.children?.first)
        func reconcile(_ disclosure: inout ChannelTask.Disclosure, _ roots: [ChannelTask]) {
            disclosure.reconcile(roots.map { ("v:\($0.id)", $0) }) { "\($0)/\($1.id)" }
        }
        var disclosure = ChannelTask.Disclosure()
        #expect(disclosure.isExpanded(active, key: "v:parent"))
        #expect(!disclosure.isExpanded(nested, key: "v:parent/nested"))

        disclosure.set(false, active, key: "v:parent")
        disclosure.set(true, nested, key: "v:parent/nested")
        reconcile(&disclosure, [active])
        #expect(!disclosure.isExpanded(active, key: "v:parent"))
        #expect(disclosure.isExpanded(nested, key: "v:parent/nested"))

        // The parent finishes while hidden, so its default flips. Reconciling drops its toggle, or the
        // toggle would apply again once the parent is back in progress. The nested default holds.
        let done = tree("done")
        reconcile(&disclosure, [done])
        #expect(!disclosure.isExpanded(done, key: "v:parent"))
        reconcile(&disclosure, [active])
        #expect(disclosure.isExpanded(active, key: "v:parent"))
        #expect(disclosure.isExpanded(nested, key: "v:parent/nested"))

        reconcile(&disclosure, [])
        #expect(!disclosure.isExpanded(nested, key: "v:parent/nested"))
    }

    @Test func theTeamKeepsTheLeadFirstAndSortsMembersLikeFinder() {
        let roster = [ChannelAgent(id: "lead", name: "Zed"), ChannelAgent(id: "b", name: "agent 10"),
                      ChannelAgent(id: "a", name: "Agent 2"), ChannelAgent(id: "c", name: "Ada"),
                      ChannelAgent(id: "d", name: "Ada")]
        #expect(roster.teamOrder.map(\.id) == ["lead", "c", "d", "a", "b"])
        #expect([ChannelAgent]().teamOrder.isEmpty)
    }
}
