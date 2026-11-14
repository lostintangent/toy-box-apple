import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// One server in Settings: its name, then its address and status, then its release. The address is
/// only how this iPhone reaches the server, so it can be copied but not edited.
struct ServerSettingsView: View {
    let catalog: ChannelCatalogStore

    var body: some View {
        Form {
            ServerNameSection(catalog: catalog)
            ServerAddressSection(catalog: catalog)
            ServerVersionSection(update: catalog.update)
        }
        .navigationTitle(catalog.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A server's Name, which renames the server itself, with why the last rename failed under it. See
/// Naming a server in docs/spec.md.
private struct ServerNameSection: View {
    @Environment(AppModel.self) private var model
    @ViewState private var field: ServerNameField
    @FocusState private var isFocused: Bool

    init(catalog: ChannelCatalogStore) {
        _field = ViewState(initialValue: ServerNameField(catalog))
    }

    var body: some View {
        @Bindable var field = field
        Section("Name") {
            TextField("Name", text: $field.text)
                .accessibilityIdentifier("server-name")
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($isFocused)
                .disabled(!field.isEditable)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in if !focused { commit() } }
                .onDisappear(perform: commit)
            if let failure = field.failure {
                FailureLabel(words: failure.words, reason: failure.reason)
            }
        }
    }

    /// A server that was removed keeps its name.
    private func commit() {
        guard model.catalogs.contains(where: { $0 === field.catalog }) else { return }
        Task { await field.commit() }
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

/// What a change in Settings couldn't do, like rename a server, after a yellow triangle on its first
/// line, with any reason under it.
struct FailureLabel: View {
    let words: String
    let reason: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 2) {
                Text(words)
                if let reason { Text(reason).font(.subheadline).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
