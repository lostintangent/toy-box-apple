import Foundation

public struct ChannelDigestWindow: Equatable, Sendable {
    public var since: Date
    public var through: Date

    public init(since: Date, through: Date) {
        self.since = since
        self.through = through
    }

    public static func morning(now: Date, calendar: Calendar, minutes: Int, lastRun: Date?,
                               coveredThrough: Date?) -> Self? {
        let minutes = (0..<720).contains(minutes) ? minutes : 480
        guard let due = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: now),
              let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now),
              now >= due, now < noon,
              lastRun.map({ $0 < calendar.startOfDay(for: now) }) ?? true else { return nil }
        return Self(since: max(now.addingTimeInterval(-86_400), min(coveredThrough ?? .distantPast, now)),
                    through: now)
    }

    public func selecting(_ state: ChannelState) -> ChannelState {
        var state = state
        state.messages = state.messages.filter {
            guard let date = ChannelDates.date($0.timestamp) else { return false }
            return date > since && date <= through
        }
        if !state.messages.contains(where: { $0.sequence == state.channel.requestSequence }) {
            state.channel.requestSequence = nil
            state.request = nil
        }
        return state
    }

    public func history(_ initial: ChannelState, isolation: isolated (any Actor)? = #isolation,
                        page: (Int) async throws -> [ChannelMessage]) async throws -> ChannelState {
        var state = initial
        var seen = Set(state.messages.map(\.sequence))
        var before = state.messages.map(\.sequence).min() ?? state.channel.latestSequence + 1
        while before > 1,
              !state.messages.contains(where: { ChannelDates.date($0.timestamp).map { $0 <= since } ?? false }) {
            try Task.checkCancellation()
            let older = try await page(before).filter { $0.sequence < before }
            guard let next = older.map(\.sequence).min(), next < before else { break }
            state.messages += older.filter { seen.insert($0.sequence).inserted }
            before = next
        }
        state.messages.sort { $0.sequence < $1.sequence }
        return selecting(state)
    }
}
