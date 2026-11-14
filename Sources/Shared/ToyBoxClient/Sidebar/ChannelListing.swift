import ChannelKit

/// The channel list as both apps show it: live from a channel's store while it's open, else from the catalog.
@MainActor
public struct ChannelListing {
    private let catalog: ChannelCatalogStore?
    private let openChannelIDs: Set<String>

    public init(catalog: ChannelCatalogStore?, openChannelIDs: Set<String>) {
        self.catalog = catalog
        self.openChannelIDs = openChannelIDs
    }

    /// Reads live details and the request independently of status and transcript events.
    /// Activity times remain the catalog's so live state does not reorder the list.
    public func channel(_ channel: Channel) -> Channel {
        guard openChannelIDs.contains(channel.id), let store = catalog?.channel(id: channel.id),
              let details = store.details else { return channel }
        var live = details.applying(to: channel, requestSequence: store.requestSequence)
        // The channel's own stream can deliver a request before the channel list does.
        live.request = store.request
        return live
    }

    public func attention(_ channel: Channel) -> Channel.Attention? {
        self.channel(channel).sidebarAttention(isOpen: openChannelIDs.contains(channel.id))
    }

    public func agents(_ channel: Channel) -> [ChannelAgent] {
        if openChannelIDs.contains(channel.id), let store = catalog?.channel(id: channel.id), store.isLoaded {
            return store.roster
        }
        return catalogAgents(channelID: channel.id)
    }

    /// The catalog's `working`, for open and closed channels alike. An open channel that becomes
    /// unavailable clears it, as its transcript and Overview do.
    public func working(_ channel: Channel, agents: [ChannelAgent]) -> [ChannelAgent] {
        guard let catalog else { return [] }
        if openChannelIDs.contains(channel.id), catalog.channel(id: channel.id).phase.isUnavailable { return [] }
        return agents.filter { catalog.working.contains($0.id) }
    }

    public func catalogAgents(channelID: String) -> [ChannelAgent] {
        guard let catalog, let lead = catalog.state?.lead else { return [] }
        return [ChannelAgent.lead(id: channelID, profile: lead)] + catalog.members.filter { $0.channelId == channelID }
    }
}
