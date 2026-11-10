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

    public static let currentVersion = 2

    /// One server's part, which only that server's catalog replaces, so a server that can't be
    /// reached keeps its own last count and requests.
    public struct Server: Codable, Equatable, Sendable {
        /// Exactly as the app saved it.
        public var serverURL: String
        public var updatedAt: Date
        public var isOffline: Bool
        public var isAvailable: Bool
        public var waitingCount: Int
        /// Its five newest, newest first.
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

        /// A server Toy Box can't reach: its last part marked offline, otherwise an unavailable one.
        public static func offline(_ serverURL: String, in previous: NeedsYouSnapshot?, at now: Date) -> Self {
            guard var part = previous?.part(at: serverURL) else {
                return .init(serverURL: serverURL, updatedAt: now, isOffline: true, isAvailable: false,
                             waitingCount: 0, requests: [])
            }
            part.isOffline = true
            part.serverURL = serverURL
            for index in part.requests.indices { part.requests[index].serverURL = serverURL }
            return part
        }
    }

    public struct Request: Codable, Equatable, Sendable, Identifiable {
        public var id: String { ChannelTarget(serverURL: serverURL, channelID: channelID)?.identifier ?? channelID }
        /// Its server exactly as the app saved it.
        public var serverURL: String
        public var channelID: String
        public var channelName: String
        public var sequence: Int
        public var quote: String
        public var requestedAt: Date?

        public init(serverURL: String, channelID: String, channelName: String, sequence: Int, quote: String,
                    requestedAt: Date?) {
            self.serverURL = serverURL
            self.channelID = channelID
            self.channelName = channelName
            self.sequence = sequence
            self.quote = quote
            self.requestedAt = requestedAt
        }
    }

    public var version = Self.currentVersion
    /// In Settings order.
    public var servers: [Server]

    public init(servers: [Server]) {
        self.servers = servers
    }

    /// Out of date when any server is.
    public var isOffline: Bool { servers.contains(where: \.isOffline) }
    /// The oldest server's last update.
    public var updatedAt: Date { servers.map(\.updatedAt).min() ?? .distantPast }
    public var isAvailable: Bool { servers.contains(where: \.isAvailable) }
    public var waitingCount: Int { servers.reduce(0) { $0 + $1.waitingCount } }

    /// The five newest across servers. Each server's own order holds, so one server reads as its
    /// catalog does, and a tie goes to the server listed first.
    public var requests: [Request] {
        var remaining = servers.map { $0.requests[...] }
        var merged: [Request] = []
        while merged.count < 5 {
            let heads = remaining.indices.filter { !remaining[$0].isEmpty }
            guard let next = heads.max(by: { first, second in
                let a = remaining[first].first?.requestedAt ?? .distantPast
                let b = remaining[second].first?.requestedAt ?? .distantPast
                return a == b ? first > second : a < b
            }) else { break }
            merged.append(remaining[next].removeFirst())
        }
        return merged
    }

    /// The version a saved snapshot was written in, read on its own, since each version's shape
    /// differs.
    public static func version(of data: Data) throws -> Int {
        struct Probe: Decodable { var version: Int }
        return try JSONDecoder().decode(Probe.self, from: data).version
    }

    /// A server's part, however its address is spelled.
    func part(at serverURL: String) -> Server? {
        guard let address = ChannelWaitingRequest.normalizedServer(serverURL) else {
            return servers.first { $0.serverURL == serverURL }
        }
        return servers.first { ChannelWaitingRequest.normalizedServer($0.serverURL) == address }
    }

    public func isStale(at now: Date) -> Bool {
        isOffline || now.timeIntervalSince(updatedAt) >= Self.freshnessInterval
    }

    /// What to write over `previous`, or nil when it would change nothing. An unchanged snapshot
    /// still rewrites every 15 minutes while a server is live, as a heartbeat. An offline server keeps
    /// the time it was last reached, and every live one is reached now.
    public func replacing(_ previous: NeedsYouSnapshot?, at now: Date) -> NeedsYouSnapshot? {
        var snapshot = self
        var heartbeatDue = false
        for index in snapshot.servers.indices {
            let part = snapshot.servers[index]
            guard let earlier = previous?.part(at: part.serverURL) else { continue }
            snapshot.servers[index].updatedAt = earlier.updatedAt
            if !part.isOffline, now.timeIntervalSince(earlier.updatedAt) >= 15 * 60 { heartbeatDue = true }
        }
        if snapshot == previous, !heartbeatDue { return nil }
        for index in snapshot.servers.indices where !snapshot.servers[index].isOffline {
            snapshot.servers[index].updatedAt = now
        }
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
