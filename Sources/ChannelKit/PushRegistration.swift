import Foundation

public enum PushEnvironment: String, Codable, Sendable {
    case sandbox, production
}

public struct PushDeviceRegistration: Codable, Equatable, Sendable {
    public var registrationID: String
    public var token: String
    public var environment: PushEnvironment
    public var requests: Bool
    public var completions: Bool

    public init(registrationID: String, token: String, environment: PushEnvironment,
                requests: Bool, completions: Bool) {
        self.registrationID = registrationID
        self.token = token
        self.environment = environment
        self.requests = requests
        self.completions = completions
    }

}

public struct PushActivityRegistration: Codable, Equatable, Sendable {
    public var registrationID: String
    public var token: String
    public var environment: PushEnvironment
    public var startedAt: Date

    public init(registrationID: String, token: String, environment: PushEnvironment, startedAt: Date) {
        self.registrationID = registrationID
        self.token = token
        self.environment = environment
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey { case registrationID, token, environment, startedAt }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(registrationID: try values.decode(String.self, forKey: .registrationID),
                  token: try values.decode(String.self, forKey: .token),
                  environment: try values.decode(PushEnvironment.self, forKey: .environment),
                  startedAt: Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .startedAt)))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(registrationID, forKey: .registrationID)
        try values.encode(token, forKey: .token)
        try values.encode(environment, forKey: .environment)
        try values.encode(startedAt.timeIntervalSince1970, forKey: .startedAt)
    }
}
