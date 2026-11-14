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
        private var waiters: [(event: String, continuation: CheckedContinuation<Void, Never>)] = []

        func record(_ event: String) {
            events.append(event)
            for waiter in waiters where waiter.event == event { waiter.continuation.resume() }
            waiters.removeAll { $0.event == event }
        }

        func wait(for event: String) async {
            if events.contains(event) { return }
            await withCheckedContinuation { waiters.append((event, $0)) }
        }
    }

    /// Starts a job that holds the queue until `gate` opens.
    func block(_ queue: GenerationQueue, _ gate: Gate, _ recorder: Recorder) async -> Task<String?, Never> {
        let task = await queue.start("block", .catchUp) {
            await recorder.record("block")
            await gate.wait()
            return "block"
        }
        await recorder.wait(for: "block")
        return task
    }

    @Test func requestsForOneKeyShareOneRun() async {
        let queue = GenerationQueue()
        let gate = Gate()
        let recorder = Recorder()
        let first = await block(queue, gate, recorder)
        let second = await queue.start("block", .visible) {
            await recorder.record("duplicate")
            return "duplicate"
        }
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
            tasks.append(await queue.start(key, priority) {
                await recorder.record(key)
                return key
            })
        }
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
        let queued = await queue.start("tile", .visible) {
            await recorder.record("tile")
            return "tile"
        }
        queued.cancel()
        #expect(await queued.value == nil)
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
        let image = await queue.start("image", .focused) {
            await recorder.record("image started")
            // A cold first description can take over a minute, so only cancellation ends it.
            if await attempts.next() == 1 {
                try? await Task.sleep(for: .seconds(60))
                await recorder.record(Task.isCancelled ? "image cancelled" : "image finished")
                return nil
            }
            return "description"
        }
        await recorder.wait(for: "image started")

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
        let tile = await queue.start("tile", .visible) {
            await recorder.record("tile started")
            await gate.wait()
            await recorder.record(Task.isCancelled ? "tile cancelled" : "tile finished")
            return "tile"
        }
        await recorder.wait(for: "tile started")
        let viewer = await queue.start("viewer", .focused) {
            await recorder.record("viewer")
            return "viewer"
        }
        await gate.open()
        #expect(await tile.value == "tile")
        #expect(await viewer.value == "viewer")
        #expect(await recorder.events == ["tile started", "tile finished", "viewer"])
    }

    @Test func cancellingTheLastWaiterCancelsTheRunAndFreesTheKey() async {
        let queue = GenerationQueue()
        let gate = Gate()
        let recorder = Recorder()
        let running = await queue.start("catch-up", .catchUp) {
            await recorder.record("started")
            await gate.wait()
            await recorder.record(Task.isCancelled ? "cancelled" : "finished")
            return "stale"
        }
        await recorder.wait(for: "started")
        running.cancel()
        #expect(await running.value == nil)
        await gate.open()
        await recorder.wait(for: "cancelled")

        let fresh = await queue.run(key: "catch-up", priority: .catchUp) { () async -> String? in "fresh" }
        #expect(fresh == "fresh")
    }
}

extension GenerationQueue {
    /// Starts a request that has joined the queue by the time this returns, so tests order requests
    /// without waiting.
    func start(_ key: String, _ priority: Priority,
               _ operation: @escaping @Sendable () async -> String?) -> Task<String?, Never> {
        Task.immediate { await self.run(key: key, priority: priority, operation) }
    }
}
