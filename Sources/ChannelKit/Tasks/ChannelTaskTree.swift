import Foundation

public func channelTasksDiff(_ tasks: [ChannelTask]) -> DiffStats? {
    var total: DiffStats?
    for task in tasks {
        for diff in [task.diff, channelTasksDiff(task.children ?? [])].compactMap({ $0 }) {
            total = .init(added: (total?.added ?? 0) + diff.added,
                          removed: (total?.removed ?? 0) + diff.removed)
        }
    }
    return total
}

/// The tasks at one level that hold work in progress, each whole, so its counts, diff and timing
/// still describe every child. Callers apply this to each level of the tree.
public func channelTasksHoldingWorkInProgress(_ tasks: [ChannelTask]) -> [ChannelTask] {
    tasks.filter(\.holdsWorkInProgress)
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

public func unassignChannelTasks(_ tasks: [ChannelTask], agentId: String) -> [ChannelTask] {
    tasks.map { task in
        var next = task
        if next.ownerId == agentId { next.ownerId = nil }
        if let children = next.children { next.children = unassignChannelTasks(children, agentId: agentId) }
        return next
    }
}

public func unlinkChannelTasks(_ tasks: [ChannelTask], artifactId: String) -> [ChannelTask] {
    tasks.map { task in
        var next = task
        if next.artifactId == artifactId { next.artifactId = nil }
        if let children = next.children { next.children = unlinkChannelTasks(children, artifactId: artifactId) }
        return next
    }
}
