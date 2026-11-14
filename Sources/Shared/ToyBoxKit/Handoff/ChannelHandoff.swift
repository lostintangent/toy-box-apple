import Foundation

public struct ChannelHandoff: Equatable, Sendable {
    public static let activityType = "dev.toybox.desktop.channel"
    public static let channelIDKey = "channelID"

    public let channelID: String

    public init(channelID: String) {
        self.channelID = channelID
    }

    public init?(activity: NSUserActivity) {
        guard activity.activityType == Self.activityType,
              let channelID = activity.userInfo?[Self.channelIDKey] as? String,
              !channelID.isEmpty else { return nil }
        self.init(channelID: channelID)
    }

    public var userInfo: [String: String] { [Self.channelIDKey: channelID] }
}
