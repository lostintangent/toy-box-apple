import Foundation

public struct ChannelActivityPush: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable { case update, end }

    public var event: Event
    public var timestamp: Date
    public var state: ChannelActivityAttributes.ContentState
    public var staleDate: Date?
    public var dismissalDate: Date?

    public init(event: Event, timestamp: Date, state: ChannelActivityAttributes.ContentState,
                staleDate: Date? = nil, dismissalDate: Date? = nil) {
        self.event = event
        self.timestamp = timestamp
        self.state = state
        self.staleDate = staleDate
        self.dismissalDate = dismissalDate
    }

    private enum CodingKeys: String, CodingKey {
        case aps, event, timestamp
        case state = "content-state"
        case staleDate = "stale-date"
        case dismissalDate = "dismissal-date"
    }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        let values = try root.nestedContainer(keyedBy: CodingKeys.self, forKey: .aps)
        self.init(
            event: try values.decode(Event.self, forKey: .event),
            timestamp: Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .timestamp)),
            state: try values.decode(ChannelActivityAttributes.ContentState.self, forKey: .state),
            staleDate: try values.decodeIfPresent(Double.self, forKey: .staleDate).map(Date.init(timeIntervalSince1970:)),
            dismissalDate: try values.decodeIfPresent(Double.self, forKey: .dismissalDate)
                .map(Date.init(timeIntervalSince1970:))
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var root = encoder.container(keyedBy: CodingKeys.self)
        var values = root.nestedContainer(keyedBy: CodingKeys.self, forKey: .aps)
        try values.encode(event, forKey: .event)
        try values.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
        try values.encode(state, forKey: .state)
        try values.encodeIfPresent(staleDate?.timeIntervalSince1970, forKey: .staleDate)
        try values.encodeIfPresent(dismissalDate?.timeIntervalSince1970, forKey: .dismissalDate)
    }

    public func reanchored(at date: Date) -> Self {
        let offset = date.timeIntervalSince(timestamp)
        var state = state
        state.updatedAt = state.updatedAt.addingTimeInterval(offset)
        return Self(event: event, timestamp: date, state: state,
                    staleDate: staleDate?.addingTimeInterval(offset),
                    dismissalDate: dismissalDate?.addingTimeInterval(offset))
    }
}
