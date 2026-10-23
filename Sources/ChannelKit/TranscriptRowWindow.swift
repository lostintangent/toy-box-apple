import Foundation

extension TranscriptRow {
    public var firstSequence: Int {
        switch content {
        case .user(let message): message.sequence
        case .agent(_, let entries): entries.first?.message.sequence ?? 0
        case .system(let messages): messages.first?.sequence ?? 0
        }
    }

    public var lastSequence: Int {
        switch content {
        case .user(let message): message.sequence
        case .agent(_, let entries): entries.last?.message.sequence ?? 0
        case .system(let messages): messages.last?.sequence ?? 0
        }
    }
}

/// The rows one transcript window mounts. The channel's store keeps every loaded message for all of
/// its windows, so each window mounts only a suffix of the full rows: the latest rows, or from a few
/// rows above the New divider or a revealed message. The suffix always starts on a row of the full
/// transcript, so its rows and their IDs are exactly the full build's, and it mounts at least
/// `latestCount` rows when that many exist.
///
/// The start is held as a sequence rather than an index, so it stays on the same row when older
/// pages prepend, or on the earlier row a prepended page merges it into. Appends extend the end and
/// never move the start. Only `showLatest`, `trimToLatest`, `land` and `reveal` move it down.
public struct TranscriptRowWindow: Equatable, Sendable {
    enum Start: Equatable, Sendable {
        /// The latest rows, sliding as messages arrive, until the transcript lands.
        case latest
        /// Every loaded row, including pages that load later.
        case oldest
        /// The row that contains this sequence, or the first row after it.
        case sequence(Int)
    }

    /// How many rows the latest suffix mounts.
    public var latestCount: Int
    /// How many rows `extendOlder` adds, and how far past `latestCount` a trim lets the suffix grow.
    public var step: Int
    /// How many rows `land` and `reveal` mount above their target row.
    public var context: Int
    private(set) var start: Start = .latest

    public init(latestCount: Int = 60, step: Int = 50, context: Int = 20) {
        self.latestCount = latestCount
        self.step = step
        self.context = context
    }

    /// The indices of the mounted rows in `rows`, which always run to the end.
    public func range(in rows: [TranscriptRow]) -> Range<Int> {
        let floor = max(0, rows.count - latestCount)
        let lower = switch start {
        case .latest: floor
        case .oldest: 0
        case .sequence(let sequence): min(Self.index(in: rows, lastSequenceAtLeast: sequence), floor)
        }
        return lower..<rows.count
    }

    public func rows(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        Array(rows[range(in: rows)])
    }

    /// The first sequence of the oldest mounted row, which changes whenever older rows mount.
    public func oldestSequence(in rows: [TranscriptRow]) -> Int? {
        let range = range(in: rows)
        return range.isEmpty ? nil : rows[range.lowerBound].firstSequence
    }

    /// Mounts up to `step` older rows and returns whether any mounted. When none are left, the window
    /// starts mounting every loaded row, so the page that the caller loads next mounts as it lands.
    @discardableResult
    public mutating func extendOlder(in rows: [TranscriptRow]) -> Bool {
        let lower = range(in: rows).lowerBound
        guard lower > 0 else {
            start = .oldest
            return false
        }
        start = .sequence(rows[max(0, lower - step)].firstSequence)
        return true
    }

    /// Mounts only the latest rows. Call it when the reader jumps to the latest message.
    public mutating func showLatest(in rows: [TranscriptRow]) {
        start = rows.isEmpty ? .latest : .sequence(rows[max(0, rows.count - latestCount)].firstSequence)
    }

    /// Unmounts older rows once more than `step` rows past `latestCount` have built up, and returns
    /// whether it did. Call it only while the reader is at the bottom and nothing is paging.
    @discardableResult
    public mutating func trimToLatest(in rows: [TranscriptRow]) -> Bool {
        let target = max(0, rows.count - latestCount)
        guard target - range(in: rows).lowerBound > step else { return false }
        start = .sequence(rows[target].firstSequence)
        return true
    }

    /// Mounts the New divider's row with `context` rows above it, or the latest rows when nothing
    /// after `unreadAfter` is loaded.
    public mutating func land(unreadAfter: Int?, in rows: [TranscriptRow]) {
        guard let unreadAfter else { return showLatest(in: rows) }
        let index = Self.index(in: rows, lastSequenceAtLeast: unreadAfter + 1)
        guard index < rows.count else { return showLatest(in: rows) }
        start = .sequence(rows[max(0, index - context)].firstSequence)
    }

    /// Mounts the row that contains `sequence` with `context` rows above it. It does nothing when
    /// that row isn't loaded.
    public mutating func reveal(sequence: Int, in rows: [TranscriptRow]) {
        let index = Self.index(in: rows, lastSequenceAtLeast: sequence)
        guard index < rows.count else { return }
        start = .sequence(rows[max(0, index - context)].firstSequence)
    }

    /// Rows follow message order, so their last sequences ascend.
    private static func index(in rows: [TranscriptRow], lastSequenceAtLeast sequence: Int) -> Int {
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].lastSequence < sequence { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
