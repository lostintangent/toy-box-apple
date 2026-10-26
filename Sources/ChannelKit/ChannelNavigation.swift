public enum ChannelNavigation {
    public enum Direction: Equatable, Sendable {
        case next
        case previous
    }

    public static func adjacent(in channelIDs: [String], from selection: String?,
                                direction: Direction) -> String? {
        guard !channelIDs.isEmpty else { return nil }
        let step = direction == .next ? 1 : -1
        let current = selection.flatMap { channelIDs.firstIndex(of: $0) } ?? (step > 0 ? -1 : 0)
        return channelIDs[(current + step + channelIDs.count) % channelIDs.count]
    }

    public static func nextAttention(in channelIDs: [String], from selection: String?,
                                     attentionIDs: Set<String>) -> String? {
        guard !channelIDs.isEmpty else { return nil }
        let current = selection.flatMap { channelIDs.firstIndex(of: $0) } ?? -1
        for offset in 1...channelIDs.count {
            let id = channelIDs[(current + offset) % channelIDs.count]
            if attentionIDs.contains(id) { return id }
        }
        return nil
    }
}
