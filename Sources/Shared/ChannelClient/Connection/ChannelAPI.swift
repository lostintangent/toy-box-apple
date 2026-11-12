import ChannelKit
import Foundation

public enum ChannelAPIError: Error, Equatable, LocalizedError, Sendable {
    case invalidServerURL
    case invalidResponse
    /// A failed response, with the server's own words when it gave them.
    case http(status: Int, message: String?)
    case invalidMessage(String)
    case disconnected
    case streamEnded
    case heartbeatTimeout
    case invalidEvent(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Enter an HTTP or HTTPS server URL."
        case .invalidResponse: "The server returned an invalid response."
        case .http(let status, let message):
            message ?? "\(HTTPURLResponse.localizedString(forStatusCode: status)) (HTTP \(status))"
        case .invalidMessage(let message): message
        case .disconnected: "The channel isn't connected."
        case .streamEnded: "The channel connection ended. Reconnecting."
        case .heartbeatTimeout: "The server stopped responding. Reconnecting."
        case .invalidEvent(let kind): "The server returned an invalid \(kind) event."
        }
    }
}

public struct ChannelHistoryPage: Codable, Sendable {
    public var revision: Int
    public var messages: [ChannelMessage]
}

public struct CreateChannelInput: Encodable, Sendable {
    public var name: String
    public var purpose: String?
    public var directory: String?
    public var model: ModelConfiguration

    public init(name: String, purpose: String? = nil, directory: String? = nil,
                model: ModelConfiguration) {
        self.name = name
        self.purpose = purpose
        self.directory = directory
        self.model = model
    }
}

public enum FieldChange<Value: Encodable & Sendable>: Encodable, Sendable {
    case set(Value)
    case clear

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .set(let value): try container.encode(value)
        case .clear: try container.encodeNil()
        }
    }
}

public struct EditChannelInput: Encodable, Sendable {
    public var name: String?
    public var purpose: FieldChange<String>?
    public var model: ModelConfiguration?

    public init(name: String? = nil, purpose: FieldChange<String>? = nil,
                model: ModelConfiguration? = nil) {
        self.name = name
        self.purpose = purpose
        self.model = model
    }
}

public struct CreateMemberInput: Encodable, Sendable {
    public var name: String
    public var role: String?
    public var model: ModelConfiguration?

    public init(name: String, role: String? = nil, model: ModelConfiguration? = nil) {
        self.name = name
        self.role = role
        self.model = model
    }
}

public struct EditMemberInput: Encodable, Sendable {
    public var name: String?
    public var role: String?
    public var model: FieldChange<ModelConfiguration>?

    public init(name: String? = nil, role: String? = nil,
                model: FieldChange<ModelConfiguration>? = nil) {
        self.name = name
        self.role = role
        self.model = model
    }
}

public struct ChannelAPI: Sendable {
    public let baseURL: URL
    let session: URLSession

    /// Streams stay open, so they share a session of their own that allows many connections to a
    /// server. On `URLSession.shared`, which allows six, six open streams would hold every other
    /// request until one closed. A session the caller supplies, as tests do, carries both.
    var streamSession: URLSession { session === URLSession.shared ? Self.streams : session }

    private static let streams: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 64
        return URLSession(configuration: configuration)
    }()

    public init(baseURL: URL, session: URLSession = .shared) throws {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
              baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw ChannelAPIError.invalidServerURL
        }
        self.baseURL = baseURL
        self.session = session
    }

    public init(serverURL: String, session: URLSession = .shared) throws {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ChannelAPIError.invalidServerURL
        }
        try self.init(baseURL: url, session: session)
    }

    /// Whether a lowercased host without brackets or a trailing dot names this Mac or phone itself.
    public static func isLoopback(host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
    }

    /// Whether this server is on this Mac or phone itself, so another machine can't reach it at
    /// this address.
    public var isLoopback: Bool {
        Self.isLoopback(host: (baseURL.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[].")))
    }

    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    public func endpoint(_ components: [String], query: [URLQueryItem] = [], scheme: String? = nil) -> URL {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.scheme = scheme ?? parts.scheme
        let suffix = components.map { $0.addingPercentEncoding(withAllowedCharacters: Self.unreserved)! }
            .joined(separator: "/")
        parts.percentEncodedPath = parts.percentEncodedPath.replacingOccurrences(of: "/+$", with: "",
                                                                                 options: .regularExpression)
            + "/" + suffix
        parts.queryItems = query.isEmpty ? nil : query
        return parts.url!
    }

    public func channelURL(channelID: String, files: [WorkspaceFile] = []) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let data = try? JSONEncoder().encode([channelID]),
              let value = String(data: data, encoding: .utf8) else { return nil }
        components.queryItems = [URLQueryItem(name: "channels", value: value)]
        if !files.isEmpty {
            guard let data = try? JSONEncoder().encode(files),
                  let value = String(data: data, encoding: .utf8) else { return nil }
            components.queryItems?.append(URLQueryItem(name: "files", value: value))
        }
        return components.url
    }

    public func resourceURL(_ address: String) -> URL? {
        if let url = URL(string: address), url.scheme != nil {
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
        guard !address.hasPrefix("//"), !address.hasPrefix("/\\") else { return nil }
        let root = baseURL.absoluteString.hasSuffix("/") ? baseURL : baseURL.appendingPathComponent("")
        return URL(string: String(address.drop(while: { $0 == "/" })), relativeTo: root)?.absoluteURL
    }

    public func catalog() async throws -> ChannelCatalog {
        try await get(["api", "v1", "channels"])
    }

    public func models() async throws -> ModelCatalog {
        try await get(["api", "v1", "models"])
    }

    public func screens() async throws -> ScreenList {
        try await get(["api", "v1", "screens"])
    }

    /// A screen's JPEG thumbnail.
    public func screenThumbnail(id: String) async throws -> Data {
        try await data(for: URLRequest(url: endpoint(["api", "v1", "screens", id, "thumbnail"]),
                                       cachePolicy: .reloadIgnoringLocalCacheData))
    }

    /// A socket that streams a screen's frames, sized to fit its viewer's pixels. A full frame of a
    /// large display can pass URLSession's 1 MiB message limit.
    public func screenSocket(id: String, size: CGSize) -> URLSessionWebSocketTask {
        let query = [("service", "screens"), ("screen", id), ("width", String(Int(size.width.rounded()))),
                     ("height", String(Int(size.height.rounded())))].map { URLQueryItem(name: $0, value: $1) }
        let scheme = baseURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        let socket = streamSession.webSocketTask(with: endpoint(["socket"], query: query, scheme: scheme))
        socket.maximumMessageSize = 16 << 20
        return socket
    }

    @discardableResult
    public func register(registrationID: String, _ input: PushRegistration) async throws -> Bool {
        let (_, response) = try await response(for: commandRequest("PUT", ["api", "v1", "push", registrationID], body: input))
        guard response.statusCode == 201 || response.statusCode == 204 else { throw ChannelAPIError.invalidResponse }
        return response.statusCode == 201
    }

    public func unregister(registrationID: String) async throws {
        try await noContent("DELETE", ["api", "v1", "push", registrationID])
    }

    public func subscribe(topic: String, registrationID: String, _ input: PushSubscription) async throws {
        try await noContent("PUT", ["api", "v1", "push", registrationID, "topics", topic], body: input)
    }

    public func unsubscribe(topic: String, registrationID: String) async throws {
        try await noContent("DELETE", ["api", "v1", "push", registrationID, "topics", topic])
    }

    public func memberModels(channelId: String, agentId: String) async throws -> ModelCatalog {
        try await get(channelPath(channelId) + ["members", agentId, "models"])
    }

    func snapshot(channelId: String) async throws -> ChannelState {
        for try await event in subscribe(channelId: channelId) {
            guard event.type == "snapshot", let state = event.state, state.channel.id == channelId else {
                throw ChannelAPIError.invalidEvent("snapshot")
            }
            return state
        }
        throw ChannelAPIError.streamEnded
    }

    public func history(channelId: String, before: Int) async throws -> ChannelHistoryPage {
        guard before > 0 else { throw ChannelAPIError.invalidMessage("History requires a positive sequence.") }
        return try await get(channelPath(channelId) + ["messages"],
                             query: [.init(name: "before", value: String(before))])
    }

    public func post(channelId: String, id: String = UUID().uuidString, content: String,
                     attachments: [ChannelAttachment] = []) async throws -> ChannelMessage {
        let request = try messageRequest(channelId: channelId, id: id, content: content, attachments: attachments)
        return try await JSONDecoder().decode(ChannelMessage.self, from: data(for: request))
    }

    /// The POST that sends a message, so the outbox can read its answer itself.
    func messageRequest(channelId: String, id: String, content: String,
                        attachments: [ChannelAttachment]) throws -> URLRequest {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            throw ChannelAPIError.invalidMessage("A message or attachment is required.")
        }
        guard trimmed.utf16.count <= ChannelMessage.maxLength else {
            throw ChannelAPIError.invalidMessage("Messages are limited to 12,000 characters.")
        }
        let body = PostInput(id: id, content: trimmed, attachments: attachments.isEmpty ? nil : attachments)
        return try commandRequest("POST", channelPath(channelId) + ["messages"], body: body)
    }

    /// The message a successful send returned, or nil when its body isn't one.
    static func sentMessage(in data: Data) -> ChannelMessage? {
        try? JSONDecoder().decode(ChannelMessage.self, from: data)
    }

    /// The error a failed response means, with the server's own message when it gives one.
    static func failure(status: Int, data: Data) -> ChannelAPIError {
        let words = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
        return .http(status: status, message: words?.contains { !$0.isWhitespace } == true ? words : nil)
    }

    public func markRead(channelId: String, sequence: Int) async throws -> Int {
        guard sequence >= 0 else { throw ChannelAPIError.invalidMessage("Read sequence cannot be negative.") }
        let result: ReadResponse = try await command("POST", channelPath(channelId) + ["read"],
                                                     body: ReadInput(sequence: sequence))
        return result.seenThrough
    }

    /// Bookmarks or unbookmarks a message. Both are idempotent, so either succeeds when the message is
    /// already that way, and only a missing or system message is rejected, with 422.
    public func bookmark(channelId: String, sequence: Int, bookmarked: Bool) async throws {
        guard sequence > 0 else { throw ChannelAPIError.invalidMessage("Bookmarks require a positive sequence.") }
        try await noContent(bookmarked ? "PUT" : "DELETE", channelPath(channelId) + ["bookmarks", String(sequence)])
    }

    public func createChannel(_ input: CreateChannelInput) async throws -> Channel {
        try await command("POST", ["api", "v1", "channels"], body: input)
    }

    public func editChannel(id: String, changes: EditChannelInput) async throws -> Channel {
        try await command("PATCH", channelPath(id), body: changes)
    }

    public func deleteChannel(id: String) async throws {
        try await noContent("DELETE", channelPath(id))
    }

    public func createMember(channelId: String, input: CreateMemberInput) async throws -> ChannelAgent {
        try await command("POST", channelPath(channelId) + ["members"], body: input)
    }

    public func editMember(channelId: String, agentId: String,
                           changes: EditMemberInput) async throws -> ChannelAgent {
        try await command("PATCH", channelPath(channelId) + ["members", agentId], body: changes)
    }

    public func removeMember(channelId: String, agentId: String) async throws {
        try await noContent("DELETE", channelPath(channelId) + ["members", agentId])
    }

    public func runRoutine(channelId: String, routineId: String) async throws {
        try await noContent("POST", channelPath(channelId) + ["routines", routineId, "run"])
    }

    public func deleteRoutine(channelId: String, routineId: String) async throws {
        try await noContent("DELETE", channelPath(channelId) + ["routines", routineId])
    }

    public func removeArtifact(channelId: String, artifactId: String) async throws {
        try await noContent("DELETE", channelPath(channelId) + ["artifacts", artifactId])
    }

    /// The server: its identity, name, accent, releases and links.
    public func server() async throws -> ServerInfo {
        try await get(Self.serverPath)
    }

    /// Renames the server for every device and lead, and answers the server. An empty name gives it
    /// back its computer's name. A 422 is a refusal, with the server's words.
    public func renameServer(_ name: String) async throws -> ServerInfo {
        try await command("PATCH", Self.serverPath, body: RenameInput(name: name))
    }

    /// Installs whatever release is newer, then answers the server's releases. The server says
    /// nothing until its package manager finishes, so this waits up to `updateTimeout`.
    public func updateServer() async throws -> ServerVersion {
        var request = URLRequest(url: endpoint(Self.serverPath + ["update"]), timeoutInterval: Self.updateTimeout)
        request.httpMethod = "POST"
        return try await JSONDecoder().decode(ServerVersion.self, from: data(for: request))
    }

    /// Restarts the server onto its installed release. It answers before it shuts down, and every
    /// stream drops until it's back.
    public func restartServer() async throws {
        try await noContent("POST", Self.serverPath + ["restart"])
    }

    static let updateTimeout: TimeInterval = 300

    /// Links another server by its origin, and answers the server. A request that reaches this
    /// server at a non-loopback address links both ends, and one at a loopback address only this
    /// one. Linking a linked server changes nothing. A 422 is a refusal, with nothing stored.
    public func link(_ address: String) async throws -> ServerInfo {
        try await command("POST", Self.linksPath, body: LinkInput(address: address))
    }

    /// Unlinks another server by its origin, and answers the server, from both ends or only this one
    /// as `link(_:)` does. Unlinking a server that isn't linked changes nothing. The address is in the
    /// query, so no intermediary drops a DELETE's body.
    public func unlink(_ address: String) async throws -> ServerInfo {
        var parts = URLComponents(url: endpoint(Self.linksPath), resolvingAgainstBaseURL: false)!
        parts.percentEncodedQuery = "address=" + address.addingPercentEncoding(withAllowedCharacters: Self.unreserved)!
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "DELETE"
        return try await JSONDecoder().decode(ServerInfo.self, from: data(for: request))
    }

    private static let serverPath = ["api", "v1", "server"]
    private static let linksPath = serverPath + ["links"]

    public func streamRequest(channelId: String, after: Int?, timeout: TimeInterval = 35) -> URLRequest {
        let query = after.map { [URLQueryItem(name: "after", value: String($0))] } ?? []
        var request = URLRequest(url: endpoint(channelPath(channelId), query: query),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    func channelPath(_ id: String) -> [String] { ["api", "v1", "channels", id] }

    private func get<Result: Decodable>(_ path: [String], query: [URLQueryItem] = []) async throws -> Result {
        let request = URLRequest(url: endpoint(path, query: query), cachePolicy: .reloadIgnoringLocalCacheData)
        return try await JSONDecoder().decode(Result.self, from: data(for: request))
    }

    private func command<Body: Encodable, Result: Decodable>(
        _ method: String, _ path: [String], body: Body
    ) async throws -> Result {
        try await JSONDecoder().decode(Result.self, from: data(for: commandRequest(method, path, body: body)))
    }

    private func commandRequest<Body: Encodable>(
        _ method: String, _ path: [String], body: Body
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func noContent<Body: Encodable>(_ method: String, _ path: [String], body: Body) async throws {
        _ = try await data(for: commandRequest(method, path, body: body))
    }

    private func noContent(_ method: String, _ path: [String]) async throws {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        _ = try await data(for: request)
    }

    private func data(for request: URLRequest) async throws -> Data {
        try await response(for: request).0
    }

    private func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ChannelAPIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.failure(status: response.statusCode, data: data)
        }
        return (data, response)
    }
}

private struct RenameInput: Encodable { var name: String }
private struct LinkInput: Encodable { var address: String }
private struct PostInput: Encodable { var id: String; var content: String; var attachments: [ChannelAttachment]? }
private struct ReadInput: Encodable { var sequence: Int }
private struct ErrorResponse: Decodable { var error: String }
private struct ReadResponse: Decodable { var seenThrough: Int }
