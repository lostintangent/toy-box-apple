import ToyBoxClient
import SwiftUI

/// A server's Name, which renames the server itself, with why the last rename failed under it. See
/// Naming a server in docs/spec.md.
public struct ServerNameRows: View {
    let servers: ChannelServers
    @ViewState private var field: ServerNameField
    @FocusState private var isFocused: Bool

    public init(_ catalog: ChannelCatalogStore, in servers: ChannelServers) {
        self.servers = servers
        _field = ViewState(initialValue: ServerNameField(catalog))
    }

    public var body: some View {
        @Bindable var field = field
        TextField("Name", text: $field.text)
            .accessibilityIdentifier("server-name")
            #if os(iOS)
            .textInputAutocapitalization(.words)
            #endif
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

    /// A server that was removed keeps its name.
    private func commit() {
        guard servers.catalogs.contains(where: { $0 === field.catalog }) else { return }
        Task { await field.commit() }
    }
}

/// What a change in Settings couldn't do, after a yellow triangle on its first line, with any reason
/// under it.
private struct FailureLabel: View {
    let words: String
    let reason: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 2) {
                Text(words)
                if let reason {
                    Text(reason)
                        #if os(macOS)
                        .font(.caption)
                        #else
                        .font(.subheadline)
                        #endif
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
