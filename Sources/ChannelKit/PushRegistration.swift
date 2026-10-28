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

public struct PushSubscription: Codable, Equatable, Sendable {
    public var token: String?
    public var startedAt: Date?

    public init(token: String? = nil, startedAt: Date? = nil) {
        self.token = token
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey { case token, startedAt }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(token: try values.decodeIfPresent(String.self, forKey: .token),
                  startedAt: try values.decodeIfPresent(Double.self, forKey: .startedAt).map(Date.init(timeIntervalSince1970:)))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(token, forKey: .token)
        try values.encodeIfPresent(startedAt?.timeIntervalSince1970, forKey: .startedAt)
    }
}
