/// A notification delivered to this device, and the rules for withdrawing the ones that no longer say something true.
public struct ChannelNotification: Equatable, Sendable {
    public var identifier: String
    /// The server a desktop notification came from, or the registration a phone push targets.
    public var scope: String
    public var channelID: String
    /// Nil for local notices, such as a reply that failed to send.
    public var kind: ChannelPushPayload.Kind?
    public var sequence: Int

    public init(identifier: String, scope: String, channelID: String,
                kind: ChannelPushPayload.Kind?, sequence: Int) {
        self.identifier = identifier
        self.scope = scope
        self.channelID = channelID
        self.kind = kind
        self.sequence = sequence
    }

    public init(identifier: String, payload: ChannelPushPayload) {
        self.init(identifier: identifier, scope: payload.registrationID, channelID: payload.channelID,
                  kind: payload.kind, sequence: payload.sequence)
    }

    /// Where a tap leads. Only a request opens on its message, so other kinds carry no sequence.
    public struct Activation: Equatable, Sendable {
        public var channelID: String
        public var sequence: Int?

        public init(channelID: String, kind: ChannelPushPayload.Kind?, sequence: Int?) {
            self.channelID = channelID
            self.sequence = kind == .request ? sequence : nil
        }
    }

    /// A request goes once its `requestSequence` changes or clears, a completion once it's been
    /// seen, and everything once its channel is active in a key window. Another scope's
    /// notifications stay until that scope is current again.
    public static func stale(_ delivered: [ChannelNotification], channels: [Channel], scope: String,
                             activeChannelID: String?) -> [String] {
        let byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return delivered.filter { item in
            guard item.scope == scope else { return false }
            if item.channelID == activeChannelID { return true }
            guard let channel = byID[item.channelID] else { return item.kind == .request }
            switch item.kind {
            case .request: return channel.requestSequence != item.sequence
            case .completion: return channel.seenThrough >= item.sequence
            case nil: return false
            }
        }.map(\.identifier)
    }
}
