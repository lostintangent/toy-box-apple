import Foundation

extension Array where Element == ChannelTask {
    public var diff: DiffStats? {
        var total: DiffStats?
        for task in self {
            for stats in [task.diff, (task.children ?? []).diff].compactMap({ $0 }) {
                total = .init(added: (total?.added ?? 0) + stats.added,
                              removed: (total?.removed ?? 0) + stats.removed)
            }
        }
        return total
    }

    /// The tasks at one level that hold work in progress, each whole, so its counts, diff and timing
    /// still describe every child. Callers apply this to each level of the tree.
    public var holdingWorkInProgress: [ChannelTask] {
        filter(\.holdsWorkInProgress)
    }

    public func unassigning(agentId: String) -> [ChannelTask] {
        map { task in
            var next = task
            if next.ownerId == agentId { next.ownerId = nil }
            if let children = next.children { next.children = children.unassigning(agentId: agentId) }
            return next
        }
    }

    public func unlinking(artifactId: String) -> [ChannelTask] {
        map { task in
            var next = task
            if next.artifactId == artifactId { next.artifactId = nil }
            if let children = next.children { next.children = children.unlinking(artifactId: artifactId) }
            return next
        }
    }
}

extension ChannelTask {
    /// Whether this task or any descendant is in progress.
    public var holdsWorkInProgress: Bool {
        status == "in_progress" || (children ?? []).contains { $0.holdsWorkInProgress }
    }

    /// Parents start collapsed unless work is in progress under them.
    public var isExpandedByDefault: Bool { holdsWorkInProgress }

    public var showsChildProgress: Bool { children?.isEmpty == false }

    public var statusDescription: String {
        switch status {
        case "in_progress": "in progress"
        case "done": "done"
        case "blocked": "blocked"
        default: "pending"
        }
    }
}

