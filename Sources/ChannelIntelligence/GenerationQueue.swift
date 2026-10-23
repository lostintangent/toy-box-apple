import Foundation

/// Runs one model generation at a time. Requests for the same key share a single run, the highest
/// priority runs first and, within a priority, the newest request wins. A run whose waiters have all
/// been cancelled is dropped before it starts, or cancelled while it runs. A catch-up is what the
/// reader is waiting on, so it takes the model from a running image description, whose callers go
/// back in line for a fresh run.
actor GenerationQueue {
    enum Priority: Int, Comparable, Sendable {
        case visible, focused, catchUp

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private final class Job {
        let id: Int
        let key: String
        var priority: Priority
        var stamp: Int
        var waiters: [Int: CheckedContinuation<(any Sendable)?, Never>] = [:]
        let operation: @Sendable () async -> (any Sendable)?
        var task: Task<Void, Never>?

        init(id: Int, key: String, priority: Priority, stamp: Int,
             operation: @escaping @Sendable () async -> (any Sendable)?) {
            self.id = id
            self.key = key
            self.priority = priority
            self.stamp = stamp
            self.operation = operation
        }
    }

    private let limit: Int
    private var jobs: [String: Job] = [:]
    private var running = 0
    private var counter = 0

    init(limit: Int = 1) {
        self.limit = limit
    }

    /// Nil when the caller was cancelled before the shared run finished.
    func run<Value: Sendable>(key: String, priority: Priority,
                              _ operation: @escaping @Sendable () async -> Value?) async -> Value? {
        if Task.isCancelled { return nil }
        counter += 1
        let waiter = counter
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(any Sendable)?, Never>) in
                enqueue(key: key, priority: priority, waiter: waiter, continuation: continuation) {
                    await operation()
                }
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiter: waiter) }
        }
        return value as? Value
    }

    var pendingCount: Int { jobs.values.filter { $0.task == nil }.count }

    func waiterCount(for key: String) -> Int { jobs[key]?.waiters.count ?? 0 }

    private func enqueue(key: String, priority: Priority, waiter: Int,
                         continuation: CheckedContinuation<(any Sendable)?, Never>,
                         operation: @escaping @Sendable () async -> (any Sendable)?) {
        counter += 1
        if let job = jobs[key] {
            job.waiters[waiter] = continuation
            if job.task == nil {
                job.priority = max(job.priority, priority)
                job.stamp = counter
            }
        } else {
            let job = Job(id: counter, key: key, priority: priority, stamp: counter, operation: operation)
            job.waiters[waiter] = continuation
            jobs[key] = job
        }
        preempt()
        pump()
    }

    private func cancel(key: String, waiter: Int) {
        guard let job = jobs[key], let continuation = job.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        guard job.waiters.isEmpty else { return }
        jobs.removeValue(forKey: key)
        job.task?.cancel()
    }

    private func preempt() {
        guard running >= limit,
              jobs.values.contains(where: { $0.task == nil && $0.priority == .catchUp }) else { return }
        for job in Array(jobs.values) where job.task != nil && job.priority < .catchUp {
            counter += 1
            let requeued = Job(id: counter, key: job.key, priority: job.priority, stamp: job.stamp,
                               operation: job.operation)
            requeued.waiters = job.waiters
            job.waiters = [:]
            jobs[job.key] = requeued
            job.task?.cancel()
        }
    }

    private func pump() {
        while running < limit {
            let next = jobs.values.filter { $0.task == nil }
                .max { ($0.priority, $0.stamp) < ($1.priority, $1.stamp) }
            guard let job = next else { return }
            running += 1
            let operation = job.operation
            let key = job.key
            let id = job.id
            job.task = Task {
                let value = await operation()
                self.finish(key: key, id: id, value: value)
            }
        }
    }

    private func finish(key: String, id: Int, value: (any Sendable)?) {
        running -= 1
        if let job = jobs[key], job.id == id {
            jobs.removeValue(forKey: key)
            for continuation in job.waiters.values { continuation.resume(returning: value) }
        }
        pump()
    }
}
