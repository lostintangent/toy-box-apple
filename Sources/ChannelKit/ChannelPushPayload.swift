import Foundation

public enum ChannelNotificationCategory {
    public static let request = ChannelPushPayload.Kind.request.rawValue
    public static let completion = ChannelPushPayload.Kind.completion.rawValue
    public static let reply = "reply"
    public static let replyFailed = "replyFailed"
}

public struct ChannelPushPayload: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case request, completion
    }

    public let kind: Kind
    public let channelID: String
    public let sequence: Int
    public let registrationID: String

    public init(kind: Kind, channelID: String, sequence: Int, registrationID: String) {
        self.kind = kind
        self.channelID = channelID
        self.sequence = sequence
        self.registrationID = registrationID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, channelID, sequence, registrationID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sequence = try values.decode(Int.self, forKey: .sequence)
        let channelID = try values.decode(String.self, forKey: .channelID)
        let registrationID = try values.decode(String.self, forKey: .registrationID)
        guard sequence > 0, !channelID.isEmpty, !registrationID.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A push requires channel and registration IDs and a positive sequence."))
        }
        self.init(kind: try values.decode(Kind.self, forKey: .kind), channelID: channelID,
                  sequence: sequence, registrationID: registrationID)
    }

    public init(userInfo: [AnyHashable: Any]) throws {
        var fields: [String: Any] = [:]
        for key in CodingKeys.allCases {
            fields[key.rawValue] = userInfo[key.rawValue]
        }
        self = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    public var userInfo: [String: Any] {
        ["kind": kind.rawValue, "channelID": channelID, "sequence": sequence, "registrationID": registrationID]
    }
}
