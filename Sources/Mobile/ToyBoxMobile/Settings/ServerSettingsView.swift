import ToyBoxClient
import ToyBoxKit
import SwiftUI
import ToyBoxUI

/// One server in Settings: its name, then its address and status, then its release. The address is
/// only how this iPhone reaches the server, so it can be copied but not edited.
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    let catalog: ChannelCatalogStore

    var body: some View {
        Form {
            Section("Name") { ServerNameRows(catalog, in: model.servers) }
            ServerAddressSection(catalog: catalog)
            ServerVersionSection(update: catalog.update)
        }
        .navigationTitle(catalog.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The release a server runs, with Restart when it has an installed release to restart onto. See
/// Updating a server in docs/spec.md.
private struct ServerVersionSection: View {
    let update: ServerUpdate

    var body: some View {
        if let release = update.version {
            Section("Version") {
                HStack {
                    Text(release.version).textSelection(.enabled)
                    if release.installedVersion != nil {
                        Spacer()
                        Button("Restart") { Task { await update.restart() } }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .disabled(!update.canRestart)
                    }
                }
            }
        }
    }
}

/// A server's page in Settings. It holds the server itself, so the page stays put when a switch
/// replaces the server's row.
struct ServerRoute: Hashable {
    let catalog: ChannelCatalogStore

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.catalog === rhs.catalog }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(catalog)) }
}
