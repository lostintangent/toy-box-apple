import Foundation

public func channelMatchesQuery(_ channel: Channel, query: String) -> Bool {
    query.isEmpty || channel.name.localizedStandardContains(query)
        || channel.purpose?.localizedStandardContains(query) == true
        || channel.directory?.localizedStandardContains(query) == true
}

/// The matching channels among the three most recent, in that order, then every other match A to Z.
public func channelChoices(_ channels: [Channel], query: String,
                           recentIDs: [String]) -> (recent: [Channel], others: [Channel]) {
    let matching = channels.filter { channelMatchesQuery($0, query: query) }
    let recent = recentIDs.prefix(3).compactMap { id in matching.first { $0.id == id } }
    let recentIDs = Set(recent.map(\.id))
    return (recent, matching.filter { !recentIDs.contains($0.id) }.sorted {
        let order = $0.name.localizedStandardCompare($1.name)
        return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    })
}
