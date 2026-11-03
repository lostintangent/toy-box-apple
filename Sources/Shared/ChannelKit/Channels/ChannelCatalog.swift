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

/// One change on the catalog stream. The stream opens with a snapshot and reopens with a fresh one,
/// so applying events in order keeps the same catalog the JSON route returns.
public enum ChannelCatalogEvent: Decodable, Equatable, Sendable {
    case snapshot(ChannelCatalog)
    /// The sorted IDs of every agent working now, sent only when the set changes.
    case working([String])
    case channelUpserted(Channel)
    case channelDeleted(channelId: String)
    case memberUpserted(ChannelAgent)
    case memberDeleted(channelId: String, agentId: String)
    /// A type this client doesn't know, which it ignores.
    case unknown(String)

    private enum CodingKeys: String, CodingKey { case type, catalog, working, channel, channelId, member, agentId }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        switch type {
        case "snapshot": self = .snapshot(try values.decode(ChannelCatalog.self, forKey: .catalog))
        case "working": self = .working(try values.decode([String].self, forKey: .working))
        case "channel.upserted": self = .channelUpserted(try values.decode(Channel.self, forKey: .channel))
        case "channel.deleted": self = .channelDeleted(channelId: try values.decode(String.self, forKey: .channelId))
        case "channel.member.upserted": self = .memberUpserted(try values.decode(ChannelAgent.self, forKey: .member))
        case "channel.member.deleted":
            self = .memberDeleted(channelId: try values.decode(String.self, forKey: .channelId),
                                  agentId: try values.decode(String.self, forKey: .agentId))
        default: self = .unknown(type)
        }
    }
}

public extension ChannelCatalog {
    /// Applies a change the way the web channel list does. Channels stay newest first, then by ID,
    /// a new member goes first, and a deleted channel takes its members with it.
    mutating func apply(_ event: ChannelCatalogEvent) {
        switch event {
        case .snapshot(let catalog):
            self = catalog
        case .working(let ids):
            working = ids
        case .channelUpserted(let channel):
            channels.removeAll { $0.id == channel.id }
            channels.append(channel)
            channels.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
        case .channelDeleted(let channelId):
            channels.removeAll { $0.id == channelId }
            members.removeAll { $0.channelId == channelId }
        case .memberUpserted(let member):
            if let index = members.firstIndex(where: { $0.id == member.id }) { members[index] = member }
            else { members.insert(member, at: 0) }
        case .memberDeleted(_, let agentId):
            members.removeAll { $0.id == agentId }
        case .unknown:
            break
        }
    }
}
