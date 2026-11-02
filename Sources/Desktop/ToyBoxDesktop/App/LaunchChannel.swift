import Foundation

/// The channel each server's key window last showed. A fresh first window opens on it, the way
/// Messages and Mail reopen where you were even when quitting closes their windows.
struct LaunchChannel {
    static let key = "lastChannelByServer"
    var defaults: UserDefaults = .standard

    func channelID(serverURL: String) -> String? { channels[serverURL] }

    func remember(_ channelID: String, serverURL: String) {
        var channels = self.channels
        guard channels[serverURL] != channelID else { return }
        channels[serverURL] = channelID
        defaults.set(channels, forKey: Self.key)
    }

    private var channels: [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }
}
