import ChannelKit
import Foundation

public enum ChannelAPIError: Error, Equatable, LocalizedError, Sendable {
    case invalidServerURL
    case invalidResponse
    case unsupportedVersion(Int)
    case http(status: Int, message: String)
    case duplicateMessage
    case invalidMessage(String)
    case disconnected
    case streamEnded
    case heartbeatTimeout
    case invalidEvent(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Enter an HTTP or HTTPS server URL."
        case .invalidResponse: "The server returned an invalid response."
        case .unsupportedVersion(let version): "This server uses unsupported protocol version \(version)."
        case .http(let status, let message): "\(message) (HTTP \(status))"
        case .duplicateMessage: "This message ID was already accepted. It was not sent again."
        case .invalidMessage(let message): message
        case .disconnected: "The channel isn't connected."
        case .streamEnded: "The channel connection ended. Reconnecting."
        case .heartbeatTimeout: "The server stopped responding. Reconnecting."
        case .invalidEvent(let kind): "The server returned an invalid \(kind) event."
        }
    }
}

public struct ChannelHistoryPage: Codable, Sendable {
    public var version: Int
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

    public func endpoint(_ components: [String], query: [URLQueryItem] = [], scheme: String? = nil) -> URL {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.scheme = scheme ?? parts.scheme
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let suffix = components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }
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
        let catalog: ChannelCatalog = try await get(["api", "v1", "channels"])
        try requireVersion(catalog.version)
        return catalog
    }

    public func models() async throws -> ModelCatalog {
        let catalog: ModelCatalog = try await get(["api", "v1", "models"])
        try requireVersion(catalog.version)
        return catalog
    }

    public func screens() async throws -> ScreenList {
        let list: ScreenList = try await get(["api", "v1", "screens"])
        try requireVersion(list.version)
        return list
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
        let catalog: ModelCatalog = try await get(channelPath(channelId) + ["members", agentId, "models"])
        try requireVersion(catalog.version)
        return catalog
    }

    func snapshot(channelId: String) async throws -> ChannelState {
        for try await event in observe(channelId: channelId) {
            guard event.type == "snapshot", let state = event.state, state.channel.id == channelId else {
                throw ChannelAPIError.invalidEvent("snapshot")
            }
            return state
        }
        throw ChannelAPIError.streamEnded
    }

    public func history(channelId: String, before: Int) async throws -> ChannelHistoryPage {
        guard before > 0 else { throw ChannelAPIError.invalidMessage("History requires a positive sequence.") }
        let page: ChannelHistoryPage = try await get(channelPath(channelId) + ["messages"],
                                                     query: [.init(name: "before", value: String(before))])
        try requireVersion(page.version)
        return page
    }

    public func post(channelId: String, id: String = UUID().uuidString, content: String,
                     attachments: [ChannelAttachment] = []) async throws -> ChannelMessage {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            throw ChannelAPIError.invalidMessage("A message or attachment is required.")
        }
        guard trimmed.utf16.count <= ChannelMessage.maxLength else {
            throw ChannelAPIError.invalidMessage("Messages are limited to 12,000 characters.")
        }
        let body = PostInput(id: id, content: trimmed, attachments: attachments.isEmpty ? nil : attachments)
        let result: MessageResponse = try await command("POST", channelPath(channelId) + ["messages"], body: body)
        try requireVersion(result.version)
        return result.message
    }

    public func markRead(channelId: String, sequence: Int) async throws -> Int {
        guard sequence >= 0 else { throw ChannelAPIError.invalidMessage("Read sequence cannot be negative.") }
        let result: ReadResponse = try await command("POST", channelPath(channelId) + ["read"],
                                                     body: ReadInput(sequence: sequence))
        try requireVersion(result.version)
        return result.seenThrough
    }

    /// Bookmarks or unbookmarks a message. Both are idempotent, so either succeeds when the message is
    /// already that way, and only a missing or system message is rejected, with 422.
    public func bookmark(channelId: String, sequence: Int, bookmarked: Bool) async throws {
        guard sequence > 0 else { throw ChannelAPIError.invalidMessage("Bookmarks require a positive sequence.") }
        try await noContent(bookmarked ? "PUT" : "DELETE", channelPath(channelId) + ["bookmarks", String(sequence)])
    }

    public func createChannel(_ input: CreateChannelInput) async throws -> Channel {
        let result: ChannelResponse = try await command("POST", ["api", "v1", "channels"], body: input)
        try requireVersion(result.version)
        return result.channel
    }

    public func editChannel(id: String, changes: EditChannelInput) async throws -> Channel {
        let result: ChannelResponse = try await command("PATCH", channelPath(id), body: changes)
        try requireVersion(result.version)
        return result.channel
    }

    public func deleteChannel(id: String) async throws {
        try await noContent("DELETE", channelPath(id))
    }

    public func createMember(channelId: String, input: CreateMemberInput) async throws -> ChannelAgent {
        let result: MemberResponse = try await command("POST", channelPath(channelId) + ["members"], body: input)
        try requireVersion(result.version)
        return result.member
    }

    public func editMember(channelId: String, agentId: String,
                           changes: EditMemberInput) async throws -> ChannelAgent {
        let result: MemberResponse = try await command("PATCH", channelPath(channelId) + ["members", agentId],
                                                       body: changes)
        try requireVersion(result.version)
        return result.member
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
            if response.statusCode == 409 { throw ChannelAPIError.duplicateMessage }
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw ChannelAPIError.http(status: response.statusCode, message: message)
        }
        return (data, response)
    }

    func requireVersion(_ version: Int) throws {
        guard version == 1 else { throw ChannelAPIError.unsupportedVersion(version) }
    }
}

private struct PostInput: Encodable { var id: String; var content: String; var attachments: [ChannelAttachment]? }
private struct ReadInput: Encodable { var sequence: Int }
private struct ErrorResponse: Decodable { var error: String }
private struct MessageResponse: Decodable { var version: Int; var message: ChannelMessage }
private struct ReadResponse: Decodable { var version: Int; var seenThrough: Int }
private struct ChannelResponse: Decodable { var version: Int; var channel: Channel }
private struct MemberResponse: Decodable { var version: Int; var member: ChannelAgent }
