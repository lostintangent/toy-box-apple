import Foundation

public enum PushEnvironment: String, Codable, Sendable {
    case sandbox, production
}

public struct PushRegistration: Codable, Equatable, Sendable {
    public var token: String
    public var environment: PushEnvironment

    public init(token: String, environment: PushEnvironment) {
        self.token = token
        self.environment = environment
    }
}

public struct PushSubscription: Encodable, Equatable, Sendable {
    public var token: String?
    public var startedAt: Date?

    public init(token: String? = nil, startedAt: Date? = nil) {
        self.token = token
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey { case token, startedAt }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(token, forKey: .token)
        try values.encodeIfPresent(startedAt?.timeIntervalSince1970, forKey: .startedAt)
    }
}
