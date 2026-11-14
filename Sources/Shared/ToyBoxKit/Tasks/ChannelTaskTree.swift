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

    /// Which parents show their children, for one visit to a channel. A parent follows its default until
    /// someone toggles it, and the toggle holds until the default changes.
    public struct Disclosure: Equatable, Sendable {
        private struct Toggle: Equatable, Sendable {
            let expandedByDefault: Bool
            let expanded: Bool
        }

        /// Toggles under the key each app names its tasks with.
        private var toggles: [String: Toggle] = [:]

        public init() {}

        public func isExpanded(_ task: ChannelTask, key: String) -> Bool {
            guard let toggle = toggles[key], toggle.expandedByDefault == task.isExpandedByDefault else {
                return task.isExpandedByDefault
            }
            return toggle.expanded
        }

        public mutating func set(_ expanded: Bool, _ task: ChannelTask, key: String) {
            toggles[key] = Toggle(expandedByDefault: task.isExpandedByDefault, expanded: expanded)
        }

        /// Drops the toggles of tasks the tree no longer holds, and of tasks whose default changed while
        /// their row was hidden, so an old toggle never comes back. Walks the whole tree, so a hidden
        /// parent still follows its work. `childKey` names a child under its parent's key.
        public mutating func reconcile(_ roots: [(key: String, task: ChannelTask)],
                                       childKey: (_ parent: String, _ child: ChannelTask) -> String) {
            var kept: [String: Toggle] = [:]
            func visit(_ key: String, _ task: ChannelTask) {
                if let toggle = toggles[key], toggle.expandedByDefault == task.isExpandedByDefault {
                    kept[key] = toggle
                }
                for child in task.children ?? [] { visit(childKey(key, child), child) }
            }
            for root in roots { visit(root.key, root.task) }
            toggles = kept
        }
    }

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

