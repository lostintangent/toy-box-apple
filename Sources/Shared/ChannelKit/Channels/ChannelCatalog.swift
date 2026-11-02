import Foundation

public struct ChannelCatalog: Codable, Equatable, Sendable {
    public var version: Int
    public var channels: [Channel]
    public var members: [ChannelAgent]
    public var working: [String]
    public var lead: ChannelLeadProfile

    public init(lead: ChannelLeadProfile, version: Int = 1, channels: [Channel] = [],
                members: [ChannelAgent] = [], working: [String] = []) {
        self.version = version
        self.channels = channels
        self.members = members
        self.working = working
        self.lead = lead
    }

    private enum CodingKeys: String, CodingKey { case version, channels, members, working, lead }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(lead: try values.decode(ChannelLeadProfile.self, forKey: .lead),
                  version: try values.decode(Int.self, forKey: .version),
                  channels: try values.decode([Channel].self, forKey: .channels),
                  members: try values.decode([ChannelAgent].self, forKey: .members),
                  working: try values.decodeIfPresent([String].self, forKey: .working) ?? [])
    }
}
