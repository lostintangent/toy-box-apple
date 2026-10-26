import Foundation

public func channelMatchesQuery(_ channel: Channel, query: String) -> Bool {
    query.isEmpty || channel.name.localizedStandardContains(query)
        || channel.purpose?.localizedStandardContains(query) == true
        || channel.directory?.localizedStandardContains(query) == true
}
