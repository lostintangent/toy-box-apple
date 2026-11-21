import ToyBoxClient
import SwiftUI

/// The end of a server's row: its version, a spinner while it checks or reconnects, or the release
/// it runs and the one a restart starts once a restart is pending. A server that can't connect shows
/// no version, since the last one it read may be stale. See Updating a server in docs/spec.md.
public struct ServerUpdateStatus: View {
    let catalog: ChannelCatalogStore

    public init(_ catalog: ChannelCatalogStore) {
        self.catalog = catalog
    }

    public var body: some View {
        let update = catalog.update
        let isConnected = catalog.phase.failure == nil
        switch update.phase {
        case .checking?:
            ProgressView().accessibilityRepresentation { Text("Checking for updates") }
        case .reconnecting?:
            ProgressView().accessibilityRepresentation { Text("Reconnecting") }
        case .restartPending?:
            if isConnected, let release = update.release, let installed = release.installedVersion {
                Text("\(release.version) → \(installed)").foregroundStyle(.secondary)
                    .accessibilityLabel("\(release.version), \(installed) after restart")
            }
        case .idle?, nil:
            if isConnected, let version = update.release?.version {
                Text(version).foregroundStyle(.secondary)
            }
        }
    }
}
