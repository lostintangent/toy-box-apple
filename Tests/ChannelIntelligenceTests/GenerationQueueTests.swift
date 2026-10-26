import Foundation
import Testing
@testable import ChannelIntelligence

struct GenerationQueueTests {
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    actor Recorder {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
    }

    func eventually(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Condition never became true")
    }

    /// Starts a job that holds the queue until `gate` opens.
    func block(_ queue: GenerationQueue, _ gate: Gate, _ recorder: Recorder) async -> Task<String?, Never> {
        let task = Task {
            await queue.run(key: "block", priority: .catchUp) { () async -> String? in
                await recorder.record("block")
                await gate.wait()
                return "block"
            }
        }
        await eventually { await recorder.events.contains("block") }
        return task
    }

    @Test func requestsForOneKeyShareOneRun() async {
        let queue = GenerationQueue()
        let gate = Gate()
        let recorder = Recorder()
        let first = await block(queue, gate, recorder)
        let second = Task {
            await queue.run(key: "block", priority: .visible) { () async -> String? in
                await recorder.record("duplicate")
                return "duplicate"
            }
        }
        await eventually { await queue.waiterCount(for: "block") == 2 }
        await gate.open()
        #expect(await first.value == "block")
        #expect(await second.value == "block")
        #expect(await recorder.events == ["block"])
    }

    @Test func higherPriorityThenNewestRunsFirst() async {
        let queue = GenerationQueue()
        let gate = Gate()
        let recorder = Recorder()
        let blocker = await block(queue, gate, recorder)
        var tasks: [Task<String?, Never>] = []
        for (key, priority) in [("old tile", GenerationQueue.Priority.visible), ("new tile", .visible), ("viewer", .focused)] {
            tasks.append(Task {
                await queue.run(key: key, priority: priority) { () async -> String? in
                    await recorder.record(key)
                    return key
                }
            })
            await eventually { await queue.waiterCount(for: key) == 1 }
        }
        #expect(await queue.pendingCount == 3)
        #expect(await recorder.events == ["block"])
        await gate.open()
        _ = await blocker.value
        for task in tasks { _ = await task.value }
        #expect(await recorder.events == ["block", "viewer", "new tile", "old tile"])
    }

    @Test func cancelledQueuedRequestNeverRuns() async {
        let queue = GenerationQueue()
        let gate = Gate()
        let recorder = Recorder()
        let blocker = await block(queue, gate, recorder)
        let queued = Task {
            await queue.run(key: "tile", priority: .visible) { () async -> String? in
                await recorder.record("tile")
                return "tile"
            }
        }
        await eventually { await queue.waiterCount(for: "tile") == 1 }
        queued.cancel()
        #expect(await queued.value == nil)
        await eventually { await queue.pendingCount == 0 }
        await gate.open()
        _ = await blocker.value
        #expect(await recorder.events == ["block"])
    }

    actor Attempts {
        private var count = 0
        func next() -> Int { count += 1; return count }
    }

    @Test func catchUpPreemptsARunningDescriptionWhichRunsAgain() async {
        let queue = GenerationQueue()
        let recorder = Recorder()
        let attempts = Attempts()
        let image = Task {
            await queue.run(key: "image", priority: .focused) { () async -> String? in
                await recorder.record("image started")
                // A cold first description can take over a minute, so only cancellation ends it.
                if await attempts.next() == 1 {
                    try? await Task.sleep(for: .seconds(60))
                    await recorder.record(Task.isCancelled ? "image cancelled" : "image finished")
                    return nil
                }
                return "description"
            }
        }
        await eventually { await recorder.events.contains("image started") }

        let catchUp = await queue.run(key: "catch-up", priority: .catchUp) { () async -> String? in
            await recorder.record("catch-up")
            return "summary"
        }
        #expect(catchUp == "summary")
        #expect(await image.value == "description")
        #expect(await recorder.events == ["image started", "image cancelled", "catch-up", "image started"])
    }

    @Test func descriptionsNeverPreemptEachOther() async {
        let queue = GenerationQueue()
        let gate = Gate()
        let recorder = Recorder()
        let tile = Task {
            await queue.run(key: "tile", priority: .visible) { () async -> String? in
                await recorder.record("tile started")
                await gate.wait()
                await recorder.record(Task.isCancelled ? "tile cancelled" : "tile finished")
                return "tile"
            }
        }
        await eventually { await recorder.events.contains("tile started") }
        let viewer = Task {
            await queue.run(key: "viewer", priority: .focused) { () async -> String? in
                await recorder.record("viewer")
                return "viewer"
            }
        }
        await eventually { await queue.waiterCount(for: "viewer") == 1 }
        await gate.open()
        #expect(await tile.value == "tile")
        #expect(await viewer.value == "viewer")
        #expect(await recorder.events == ["tile started", "tile finished", "viewer"])
    }

    @Test func cancellingTheLastWaiterCancelsTheRunAndFreesTheKey() async {
        let queue = GenerationQueue()
        let gate = Gate()
        let recorder = Recorder()
        let running = Task {
            await queue.run(key: "catch-up", priority: .catchUp) { () async -> String? in
                await recorder.record("started")
                await gate.wait()
                await recorder.record(Task.isCancelled ? "cancelled" : "finished")
                return "stale"
            }
        }
        await eventually { await recorder.events.contains("started") }
        running.cancel()
        #expect(await running.value == nil)
        await gate.open()
        await eventually { await recorder.events.contains("cancelled") }

        let fresh = await queue.run(key: "catch-up", priority: .catchUp) { () async -> String? in "fresh" }
        #expect(fresh == "fresh")
    }
}
