import Foundation

/// A model provider on a Toy Box server, in the order Settings lists them.
public struct ModelProvider: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case ready
        case signedOut
        case failed
        case unavailable
    }

    public var id: String
    public var name: String
    public var status: Status
    /// The native discovery error when `status` is `failed`.
    public var error: String?
    public var version: String?
    public var enabled: Bool

    public init(id: String, name: String, status: Status, error: String? = nil,
                version: String? = nil, enabled: Bool) {
        self.id = id
        self.name = name
        self.status = status
        self.error = error
        self.version = version
        self.enabled = enabled
    }

    /// Whether Settings reads this provider's subscription. Only an enabled, ready provider has an
    /// account the CLI can ask.
    public var readsUsage: Bool { enabled && status == .ready }
}

/// What `GET /api/v1/providers` answers.
public struct ModelProviderList: Codable, Equatable, Sendable {
    public var providers: [ModelProvider]

    public init(providers: [ModelProvider]) {
        self.providers = providers
    }
}

/// The signed-in account's plan and limits, or the body of a non-null subscription response.
public struct ModelProviderSubscription: Codable, Equatable, Sendable {
    /// The plan's native name, such as `pro`, `max`, or `enterprise`.
    public var plan: String
    /// Empty when the plan meters nothing.
    public var limits: [ModelProviderLimit]

    public init(plan: String, limits: [ModelProviderLimit] = []) {
        self.plan = plan
        self.limits = limits
    }
}

public struct ModelProviderLimit: Codable, Equatable, Sendable {
    public var name: String
    public var usedPercent: Double
    /// When this limit renews. Nil when the provider doesn't say.
    public var resetsAt: Date?

    public init(name: String, usedPercent: Double, resetsAt: Date? = nil) {
        self.name = name
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    enum CodingKeys: String, CodingKey { case name, usedPercent, resetsAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        if let ms = try container.decodeIfPresent(Int64.self, forKey: .resetsAt) {
            resetsAt = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        } else {
            resetsAt = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(usedPercent, forKey: .usedPercent)
        if let resetsAt {
            try container.encode(Int64((resetsAt.timeIntervalSince1970 * 1000).rounded()), forKey: .resetsAt)
        }
    }
}
