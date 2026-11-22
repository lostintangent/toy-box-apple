import ToyBoxClient
import ToyBoxKit
import SwiftUI
import ToyBoxUI

/// One server in Settings: its Server Details, with its name, URL, status and release, then its
/// model providers. The URL is only how this iPhone reaches the server, so it can be copied but not
/// edited.
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    let catalog: ChannelCatalogStore

    var body: some View {
        Form {
            Section("Server Details") {
                ServerNameRows(catalog, in: model.servers)
                LabeledContent("URL") {
                    // Secondary, so a value that can't change reads apart from a filled field.
                    Text(catalog.api.baseURL.absoluteString).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ServerStatusRow(catalog)
                if let error = catalog.phase.failure {
                    ServerErrorLabel(message: ServerConnectionSection.failureMessage(error),
                                     help: ServerConnectionSection.failureHelp)
                }
                ServerVersionRow(update: catalog.update)
            }
            ModelProvidersSection(catalog)
        }
        .accessibilityIdentifier("server-settings")
        .task { await catalog.providers.appear() }
        .navigationTitle(catalog.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The release a server runs, with Restart when it has an installed release to restart onto. See
/// Updating a server in docs/spec.md.
private struct ServerVersionRow: View {
    let update: ServerUpdate

    var body: some View {
        if let release = update.release {
            LabeledContent("Version") {
                HStack(spacing: 12) {
                    Text(release.version).foregroundStyle(.secondary).textSelection(.enabled)
                    if release.isUpdatable {
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
