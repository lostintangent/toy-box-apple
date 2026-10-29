import Foundation

public struct NeedsYouSnapshot: Codable, Equatable, Sendable {
    public static let appGroup = "RHFNBL7EG4.dev.toybox.desktop"
    public static let groupInfoKey = "ToyBoxWidgetAppGroup"
    public static let fileName = "needs-you.json"
    public static let kind = "ToyBoxNeedsYou"
    public static let controlKind = "ToyBoxNeedsYouControl"
    public static let quickSendControlKind = "ToyBoxQuickSendControl"
    public static let freshnessInterval: TimeInterval = 30 * 60
    public static let mainURL = URL(string: "toybox-desktop://needs-you")!

    public struct Request: Codable, Equatable, Sendable, Identifiable {
        public var id: String { channelID }
        public var channelID: String
        public var channelName: String
        public var sequence: Int
        public var quote: String
        public var requestedAt: Date?

        public init(channelID: String, channelName: String, sequence: Int, quote: String,
                    requestedAt: Date?) {
            self.channelID = channelID
            self.channelName = channelName
            self.sequence = sequence
            self.quote = quote
            self.requestedAt = requestedAt
        }
    }

    public var version = 1
    public var serverURL: String
    public var updatedAt: Date
    public var isOffline: Bool
    public var isAvailable: Bool
    public var waitingCount: Int
    public var requests: [Request]

    public init(serverURL: String, updatedAt: Date, isOffline: Bool, isAvailable: Bool,
                waitingCount: Int, requests: [Request]) {
        self.serverURL = serverURL
        self.updatedAt = updatedAt
        self.isOffline = isOffline
        self.isAvailable = isAvailable
        self.waitingCount = waitingCount
        self.requests = requests
    }

    public func isStale(at now: Date) -> Bool {
        isOffline || now.timeIntervalSince(updatedAt) >= Self.freshnessInterval
    }

    /// What to write over `previous`, or nil when it would change nothing. An unchanged live snapshot
    /// still rewrites every 15 minutes as a heartbeat. Offline keeps the server's last reached time.
    public func replacing(_ previous: NeedsYouSnapshot?, at now: Date) -> NeedsYouSnapshot? {
        var snapshot = self
        if let previous, previous.serverURL == serverURL {
            snapshot.updatedAt = previous.updatedAt
            if snapshot == previous, isOffline || now.timeIntervalSince(previous.updatedAt) < 15 * 60 { return nil }
        }
        if !isOffline { snapshot.updatedAt = now }
        return snapshot
    }
}

/// Lossless Mac route payload for exact saved-server matching, unlike the normalized
/// `ChannelWaitingRequest.Identity` lookup key.
public struct NeedsYouRequestLink: Equatable, Sendable {
    public var serverURL: String
    public var channelID: String
    public var sequence: Int

    public init(serverURL: String, channelID: String, sequence: Int) {
        self.serverURL = serverURL
        self.channelID = channelID
        self.sequence = sequence
    }

    public init?(url: URL) {
        self.init(url: url, action: "request")
    }

    public init?(replyURL: URL) {
        self.init(url: replyURL, action: "reply")
    }

    private init?(url: URL, action: String) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "toybox-desktop", parts.host == action,
              parts.path.isEmpty, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 3,
              Set(items.map(\.name)) == ["server", "channel", "sequence"],
              let server = items.first(where: { $0.name == "server" })?.value,
              let serverParts = URLComponents(string: server),
              let scheme = serverParts.scheme, ["http", "https"].contains(scheme),
              serverParts.host?.isEmpty == false, serverParts.user == nil,
              serverParts.password == nil, serverParts.fragment == nil,
              let channel = items.first(where: { $0.name == "channel" })?.value, !channel.isEmpty,
              let value = items.first(where: { $0.name == "sequence" })?.value,
              let sequence = Int(value), sequence > 0 else { return nil }
        self.init(serverURL: server, channelID: channel, sequence: sequence)
    }

    public var url: URL? {
        url(action: "request")
    }

    public var replyURL: URL? {
        url(action: "reply")
    }

    private func url(action: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "toybox-desktop"
        parts.host = action
        parts.queryItems = [
            .init(name: "server", value: serverURL),
            .init(name: "channel", value: channelID),
            .init(name: "sequence", value: String(sequence)),
        ]
        return parts.url
    }
}
