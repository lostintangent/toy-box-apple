import Foundation

public enum PushEnvironment: String, Codable, Sendable {
    case sandbox, production
}

public struct PushRegistration: Codable, Equatable, Sendable {
    public var registrationID: String
    public var token: String
    public var environment: PushEnvironment

    public init(registrationID: String, token: String, environment: PushEnvironment) {
        self.registrationID = registrationID
        self.token = token
        self.environment = environment
    }

}

public struct PushSubscription: Codable, Equatable, Sendable {
    public var registrationID: String
    public var token: String?
    public var environment: PushEnvironment?
    public var startedAt: Date?

    public init(registrationID: String, token: String? = nil, environment: PushEnvironment? = nil, startedAt: Date? = nil) {
        self.registrationID = registrationID
        self.token = token
        self.environment = environment
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey { case registrationID, token, environment, startedAt }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(registrationID: try values.decode(String.self, forKey: .registrationID),
                  token: try values.decodeIfPresent(String.self, forKey: .token),
                  environment: try values.decodeIfPresent(PushEnvironment.self, forKey: .environment),
                  startedAt: try values.decodeIfPresent(Double.self, forKey: .startedAt).map(Date.init(timeIntervalSince1970:)))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(registrationID, forKey: .registrationID)
        try values.encodeIfPresent(token, forKey: .token)
        try values.encodeIfPresent(environment, forKey: .environment)
        try values.encodeIfPresent(startedAt?.timeIntervalSince1970, forKey: .startedAt)
    }
}
