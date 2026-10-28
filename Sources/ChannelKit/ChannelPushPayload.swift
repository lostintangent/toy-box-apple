import CoreFoundation
import Foundation

public enum ChannelNotificationCategory {
    public static let request = ChannelPushPayload.Kind.request.rawValue
    public static let completion = ChannelPushPayload.Kind.completion.rawValue
    public static let reply = "reply"
    public static let replyFailed = "replyFailed"
}

public struct ChannelPushPayload: Equatable, Sendable {
    public enum Kind: String, Sendable {
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

    public init(userInfo: [AnyHashable: Any]) throws {
        guard let kind = (userInfo["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let channelID = userInfo["channelID"] as? String, !channelID.isEmpty,
              let registrationID = userInfo["registrationID"] as? String, !registrationID.isEmpty,
              let number = userInfo["sequence"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let sequence = number as? Int, sequence > 0, sequence < Int.max else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "A push requires channel and registration IDs and a positive sequence."))
        }
        self.init(kind: kind, channelID: channelID, sequence: sequence, registrationID: registrationID)
    }
}
