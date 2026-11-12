import ChannelClient
import SwiftUI
import ToyBoxUI

/// A server's Linked switch in its own card under Server URL, the Tailscale addresses linking it
/// needs, and each pair its last change couldn't link. See Linking servers in docs/spec.md.
struct LinkedSection: View {
    let catalog: ChannelCatalogStore
    @Environment(AppModel.self) private var model
    /// Each field the card has asked for stays while it shows, so one doesn't vanish once it's saved.
    @ViewState private var asked: [String] = []
    @ViewState private var addresses = LinkAddresses()

    var body: some View {
        let linked = LinkedSwitch(catalog, in: model.catalogs)
        Section {
            Toggle("Linked", isOn: Binding(get: { linked.isOn }, set: { isOn in Task { await setLinked(isOn) } }))
                .disabled(linked.isDisabled)
            ForEach(asked, id: \.self) { address in
                if let value = linked.linkedAddress(for: address) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(linked.addressLabel(for: address)).font(.subheadline).foregroundStyle(.secondary)
                        // Secondary, so a value that can't change reads apart from a filled field.
                        Text(value).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    LinkAddressField(addresses: addresses, address: address, label: linked.addressLabel(for: address)) {
                        addresses.save([address], in: model.catalogs, with: model.setTailscaleAddress)
                    }
                }
            }
            ForEach(catalog.links.failures) { failure in
                HStack {
                    FailureLabel(words: linked.words(failure), reason: linked.reason(failure))
                    Spacer(minLength: 8)
                    // Borderless, so only the button answers a tap and not the whole row.
                    Button("Try Again") { Task { await model.catalogs.tryAgain(catalog, failure) } }
                        .buttonStyle(.borderless)
                        .disabled(model.catalogs.isChangingLinks)
                }
            }
        } footer: {
            Text(LinkAddressField.captions(for: asked.filter { linked.linkedAddress(for: $0) == nil },
                                           in: model.catalogs, before: linked.footer))
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

/// The Add Server page's Linked switch, on by default, and the Tailscale addresses linking the new
/// server needs.
struct AddServerLinkedSection: View {
    let address: String
    @Binding var isOn: Bool
    let addresses: LinkAddresses
    @Environment(AppModel.self) private var model

    var body: some View {
        let needed = isOn ? model.catalogs.serversNeedingAddress(toLink: address) : []
        Section {
            Toggle("Linked", isOn: $isOn)
            ForEach(needed, id: \.self) { server in
                LinkAddressField(addresses: addresses, address: server,
                                 label: LinkedSwitch.addressLabel(for: server, on: address, in: model.catalogs)) {
                    addresses.validate([server], in: model.catalogs)
                }
            }
        } footer: {
            Text(LinkAddressField.captions(for: needed, in: model.catalogs,
                                           before: LinkedSwitch.footer(addingServerAt: address, isOn: isOn, in: model.catalogs)))
        }
    }
}

/// One server's Tailscale address, its label above it, committed when it's submitted or loses focus.
/// What it's for leads the card's footer.
private struct LinkAddressField: View {
    let addresses: LinkAddresses
    let address: String
    let label: String
    let commit: () -> Void
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The field itself carries the label for VoiceOver.
            Text(label).font(.subheadline).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(label, text: Binding(get: { addresses.text(address, in: model.catalogs) },
                                           set: { addresses.set($0, for: address) }),
                      prompt: Text(LinkedSwitch.addressPlaceholder))
                .accessibilityLabel(label)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            if let error = addresses.errors[address] {
                Label {
                    Text(error)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                .font(.footnote)
            }
        }
    }
}

extension LinkAddressField {
    /// A footer that starts with what the card's fields are for.
    static func captions(for addresses: [String], in catalogs: [ChannelCatalogStore],
                         before footer: String) -> AttributedString {
        guard let caption = LinkedSwitch.addressCaption(for: addresses, in: catalogs) else { return AttributedString(footer) }
        return caption + AttributedString(" " + footer)
    }
}

/// What a change in Settings couldn't do, like link a pair or rename a server, after a yellow
/// triangle on its first line, with the reason under it.
struct FailureLabel: View {
    let words: String
    let reason: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 2) {
                Text(words)
                Text(reason).font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
