import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ChannelEditor: View {
    let flow: ManagementFlow
    let store: ChannelStore?
    @Bindable var presenter: ManagementPresenter
    let host: OverviewPlacement?
    @Environment(AppModel.self) private var app
    @Environment(Overview.self) private var presentation
    @FocusState private var focus: ManagementField?

    private var form: ChannelForm { presenter.channelForm }
    private var channel: ChannelDetails? { form.channel }
    private var saving: Bool { presenter.isPending }
    /// A sheet that's leaving leaves the presenter alone.
    private var isCurrent: Bool { presenter.flow?.id == flow.id }
    private var isCurrentHost: Bool { host == nil || host == presentation.placement }

    private var canSave: Bool {
        form.isSubmittable && !saving && catalog != nil && (store == nil || store?.phase.isConnected == true)
    }
    /// The channel's server, or the one New Channel creates on, which its Server menu changes.
    private var catalog: ChannelCatalogStore? { (presenter.flow ?? flow).catalog(in: app.catalogs) }
    private var serverSelection: Binding<String> {
        Binding { catalog?.api.baseURL.absoluteString ?? flow.server } set: { presenter.flow = .newChannel(server: $0) }
    }

    var body: some View {
        Form {
            if channel == nil, app.servers.shown.count > 1 {
                Section {
                    Picker("Server", selection: serverSelection) {
                        ForEach(app.servers.shown, id: \.api.baseURL) { catalog in
                            Text(catalog.name).tag(catalog.api.baseURL.absoluteString)
                        }
                    }
                    .accessibilityIdentifier("channel-server")
                }
            }
            if let store, store.phase.isUnavailable {
                Section { ManagementConnectionNotice(store: store) }
            }
            if let error = presenter.error { Section { ManagementError(message: error) } }
            Section {
                LabeledContent {
                    TextField("Name", text: $presenter.channelForm.name,
                              prompt: Text("Required").foregroundStyle(ChannelInk.secondary))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .purpose }
                        .accessibilityIdentifier("channel-name")
                } label: {
                    Text("Name").accessibilityIdentifier("channel-name-label")
                }
                TextField("Purpose", text: $presenter.channelForm.purpose,
                          prompt: Text("What should this team work toward?").foregroundStyle(ChannelInk.secondary),
                          axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focus, equals: .purpose)
                    .accessibilityIdentifier("channel-purpose")
            } footer: {
                if let violation = form.nameViolation ?? form.purposeViolation {
                    ManagementError(message: violation, systemImage: "exclamationmark.circle.fill")
                }
            }
            if let catalog {
                ModelSelectionFields(model: $presenter.channelForm.model, openingModel: channel?.model,
                                     api: catalog.api, provider: channel?.model.provider,
                                     allowsInheritance: false, title: "Lead model",
                                     help: channel == nil ? [] : ["Model changes apply the next time the lead works."])
                    // Another server's models load fresh.
                    .id(ObjectIdentifier(catalog))
            }
        }
        .accessibilityIdentifier("channel-editor-form")
        .disabled(saving)
        .navigationTitle(channel == nil ? "New Channel" : "Edit Channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { if isCurrent { presenter.flow = nil } }
                    .accessibilityLabel("Cancel")
                    .disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                ManagementConfirmButton(
                    label: saving ? (channel == nil ? "Creating…" : "Saving…") : channel == nil ? "Create Channel" : "Save",
                    pendingSince: presenter.pendingSince, identifier: "channel-submit", action: submit)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear {
            focus = presenter.focus
        }
        .onChange(of: focus) { _, field in
            if isCurrentHost, isCurrent { presenter.focus = field }
        }
        .onChange(of: presenter.focus) { _, field in
            if isCurrentHost { focus = field }
        }
    }

    private func submit() {
        guard canSave, let catalog else { return }
        Task { await presenter.save(on: catalog) }
    }
}
