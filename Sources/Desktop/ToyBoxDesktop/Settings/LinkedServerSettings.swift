import ChannelClient
import SwiftUI
import ToyBoxUI

/// A server's Linked switch in its own card, the Tailscale addresses linking it needs, and each pair
/// its last change couldn't link. See Linking servers in docs/spec.md.
struct LinkedSection: View {
    let catalog: ChannelCatalogStore
    @Environment(AppModel.self) private var model
    /// Each field the card has asked for stays while it shows, so one doesn't vanish once it's saved.
    @ViewState private var asked: [String] = []
    @ViewState private var addresses = LinkAddresses()

    var body: some View {
        let linked = LinkedSwitch(catalog, in: model.catalogs)
        Section {
            Toggle(isOn: Binding(get: { linked.isOn }, set: { isOn in Task { await setLinked(isOn) } })) {
                // A disabled switch leaves its label bright on the Mac, so the label dims with it.
                Text("Linked").foregroundStyle(linked.isAvailable ? Color.primary : Color(nsColor: .disabledControlTextColor))
            }
            .disabled(linked.isDisabled)
            ForEach(asked, id: \.self) { address in
                if let value = linked.linkedAddress(for: address) {
                    LabeledContent(linked.addressLabel(for: address)) { Text(value).textSelection(.enabled) }
                } else {
                    LinkAddressField(addresses: addresses, address: address, label: linked.addressLabel(for: address)) {
                        addresses.save([address], in: model.catalogs, with: model.setTailscaleAddress)
                    }
                }
            }
            ForEach(catalog.links.failures) { failure in
                HStack {
                    LinkFailureLabel(words: linked.words(failure), reason: linked.reason(failure))
                    Spacer()
                    if LinkedSwitch.offersTryAgain(failure) {
                        Button("Try Again") { Task { await model.catalogs.tryAgain(catalog, failure) } }
                            .controlSize(.small)
                            .disabled(model.catalogs.isChangingLinks)
                    }
                }
            }
        } footer: {
            Text(linked.footer).font(.footnote).foregroundStyle(.secondary)
        }
        .onChange(of: linked.addressesAsked, initial: true) { _, addresses in
            asked += addresses.filter { !asked.contains($0) }
        }
    }

    private func setLinked(_ isOn: Bool) async {
        guard !isOn || addresses.save(asked, in: model.catalogs, with: model.setTailscaleAddress) else { return }
        await model.catalogs.setLinked(catalog, isOn)
    }
}

/// Add Server's Linked switch, on by default, and the Tailscale addresses linking the new server
/// needs.
struct AddServerLinkedSection: View {
    let address: String
    @Binding var isOn: Bool
    let addresses: LinkAddresses
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle("Linked", isOn: $isOn)
            if isOn {
                ForEach(model.catalogs.serversNeedingAddress(toLink: address), id: \.self) { needed in
                    LinkAddressField(addresses: addresses, address: needed,
                                     label: LinkedSwitch.addressLabel(for: needed, in: model.catalogs)) {
                        addresses.validate([needed], in: model.catalogs)
                    }
                }
            }
        } footer: {
            Text(LinkedSwitch.footer(addingServerAt: address, isOn: isOn, in: model.catalogs))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// One server's Tailscale address, committed when it's submitted or loses focus, with what it's for
/// under it, or why it isn't one.
private struct LinkAddressField: View {
    let addresses: LinkAddresses
    let address: String
    let label: String
    let commit: () -> Void
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(label, text: Binding(get: { addresses.text(address, in: model.catalogs) },
                                       set: { addresses.set($0, for: address) }),
                  prompt: Text(LinkedSwitch.addressPlaceholder))
            .textContentType(.URL)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
        if let error = addresses.errors[address] {
            Label {
                Text(error).foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
            }
            .font(.caption).textSelection(.enabled)
        } else {
            Text(LinkedSwitch.addressCaption(for: address, in: model.catalogs))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A pair the last change couldn't link, after a yellow triangle on its first line, with the reason
/// under it.
private struct LinkFailureLabel: View {
    let words: String
    let reason: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 2) {
                Text(words)
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
