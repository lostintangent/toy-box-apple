import Foundation
import Testing
@testable import ChannelKit

struct ChannelTrayTests {
    @Test func trayProjectionUsesCanonicalOrderAndDirectRootProgressWithoutMutatingInputs() {
        let artifacts = [
            ChannelArtifact(file: .init(kind: "machine", path: "/old.md"), title: "Old",
                            sharedAt: "2026-10-24T08:00:00Z"),
            ChannelArtifact(file: .init(kind: "machine", path: "/new.md"), title: "New",
                            sharedAt: "2026-10-24T09:00:00Z"),
        ]
        let tasks = [
            ChannelTask(id: "parent", title: "Parent", status: "in_progress", children: [
                .init(id: "child", title: "Done child", status: "done"),
            ]),
            ChannelTask(id: "done", title: "Done root", status: "done"),
        ]
        let preview = ChannelPreview(kind: "screen", screenId: "display-1")
        let projection = ChannelTray(artifacts: artifacts, tasks: tasks, preview: preview)
        #expect(projection.artifacts == [artifacts[1], artifacts[0]])
        #expect(projection.taskProgress == .init(done: 1, total: 2))
        #expect(projection.hasTasks)
        #expect(projection.preview == preview)
        #expect(projection.isVisible)
        #expect(artifacts[0].title == "Old")
        #expect(tasks[0].children?.count == 1)
    }

    @Test func trayVisibilityPreservesEveryIndependentlyPresentSlice() {
        let artifact = ChannelArtifact(file: .init(kind: "machine", path: "/plan.md"), title: "Plan")
        let task = ChannelTask(id: "root", title: "Root", status: "done")
        for artifacts in [[], [artifact]] {
            for tasks in [[], [task]] {
                for preview in [nil, ChannelPreview(kind: "url", url: "https://example.com"),
                                ChannelPreview(kind: "screen", screenId: "display-1"),
                                ChannelPreview(kind: "future")] {
                    let projection = ChannelTray(artifacts: artifacts, tasks: tasks, preview: preview)
                    #expect(projection.isVisible == (!artifacts.isEmpty || !tasks.isEmpty || preview != nil))
                    #expect(projection.hasTasks == !tasks.isEmpty)
                    #expect(projection.preview == preview)
                    #expect(projection.taskProgress.fraction == (tasks.isEmpty ? 0 : 1))
                }
            }
        }
    }
}
