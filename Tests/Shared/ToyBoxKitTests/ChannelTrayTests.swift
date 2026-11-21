import Foundation
import Testing
@testable import ToyBoxKit

struct ChannelTrayTests {
    @Test func trayOrdersArtifactsNewestFirstAndCountsRootProgress() {
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
                    #expect(projection.taskProgress == .init(done: tasks.count, total: tasks.count))
                }
            }
        }
        #expect(ChannelTray(artifacts: [], tasks: [], preview: nil, bookmarkCount: 1).isVisible)
        #expect(!ChannelTray(artifacts: [], tasks: [], preview: nil, bookmarkCount: 0).isVisible)
    }
}
