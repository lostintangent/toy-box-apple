import ChannelClient
import Foundation
import Observation

enum AppConfiguration {
    static let serverURLKey = "serverURL"
    static let defaultServerURL = ProcessInfo.processInfo.environment["TOY_BOX_SERVER_URL"]
        ?? "http://localhost:3100"
}

/// App-wide state shared by every window: the configured server and its one catalog.
/// Each channel's `ChannelStore` comes from the catalog, so windows showing the same channel share it.
@MainActor @Observable
final class AppModel {
    private(set) var serverURL: String
    private(set) var catalog: ChannelCatalogStore?
    private(set) var configurationError: String?

    init() {
        serverURL = UserDefaults.standard.string(forKey: AppConfiguration.serverURLKey)
            ?? AppConfiguration.defaultServerURL
        configure(serverURL: serverURL)
    }

    var api: ChannelAPI? { catalog?.api }

    func configure(serverURL: String) {
        catalog?.stopPolling()
        self.serverURL = serverURL
        UserDefaults.standard.set(serverURL, forKey: AppConfiguration.serverURLKey)
        do {
            catalog = ChannelCatalogStore(api: try ChannelAPI(serverURL: serverURL))
            configurationError = nil
        } catch {
            catalog = nil
            configurationError = error.localizedDescription
        }
    }
}
