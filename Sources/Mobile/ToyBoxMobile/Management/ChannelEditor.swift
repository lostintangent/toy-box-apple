import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ChannelEditor: View {
    let store: ChannelStore?
    let presenter: ManagementPresenter
    @Bindable var session: ManagementSession
    let host: OverviewPlacement?
    @Environment(AppModel.self) private var app
    @Environment(ManagementSessions.self) private var sessions
    @Environment(Overview.self) private var presentation
    @FocusState private var focus: ManagementField?

    private var api: ChannelAPI { session.api }
    private var form: ChannelForm { session.channelForm }
    private var channel: ChannelDetails? { form.channel }
    private var saving: Bool { session.pending }
    private var isCurrent: Bool { sessions.isCurrent(session, app: app, presenter: presenter) }
    private var isCurrentHost: Bool { host == nil || host == presentation.placement }

    private var canSave: Bool {
        form.isSubmittable && !saving && (store == nil || store?.phase.isConnected == true)
    }
    private var catalog: ChannelCatalogStore? {
        app.catalogs.contains { $0 === session.catalog } ? session.catalog : nil
    }
    private var serverSelection: Binding<String> {
        Binding { session.catalog.api.baseURL.absoluteString } set: { address in
            if let chosen = app.catalogs.first(at: address) { session.catalog = chosen }
        }
    }

    var body: some View {
        Form {
            if channel == nil, app.catalogs.count > 1 {
                Section {
                    Picker("Server", selection: serverSelection) {
                        ForEach(app.catalogs, id: \.api.baseURL) { catalog in
                            Text(catalog.name).tag(catalog.api.baseURL.absoluteString)
                        }
                    }
                    .accessibilityIdentifier("channel-server")
                }
            }
            if let store, store.phase.isUnavailable {
                Section { ManagementConnectionNotice(store: store) }
            }
            if let error = session.error { Section { ManagementError(message: error) } }
            Section {
                LabeledContent {
                    TextField("Name", text: $session.channelForm.name,
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
                TextField("Purpose", text: $session.channelForm.purpose,
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
            ModelSelectionFields(model: $session.channelForm.model, openingModel: channel?.model,
                                 api: api, provider: channel?.model.provider,
                                 allowsInheritance: false, title: "Lead model",
                                 help: channel == nil ? [] : ["Model changes apply the next time the lead works."])
                // Another server's models load fresh.
                .id(ObjectIdentifier(session.catalog))
        }
        .accessibilityIdentifier("channel-editor-form")
        .disabled(saving)
        .navigationTitle(channel == nil ? "New Channel" : "Edit Channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { sessions.cancel(session, presenter: presenter) }
                    .accessibilityLabel("Cancel")
                    .disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                ManagementConfirmButton(
                    label: saving ? (channel == nil ? "Creating…" : "Saving…") : channel == nil ? "Create Channel" : "Save",
                    pendingSince: session.pendingSince, identifier: "channel-submit", action: submit)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear {
            focus = session.focus
        }
        .onChange(of: focus) { _, field in
            if isCurrentHost, isCurrent { session.focus = field }
        }
        .onChange(of: session.focus) { _, field in
            if isCurrentHost { focus = field }
        }
    }

    private func submit() {
        guard canSave else { return }
        let submittedFocus = focus
        let submittedFlow = presenter.flow
        let form = form
        session.pending = true
        session.error = nil
        let catalog = catalog
        let api = api
        Task {
            var failed = false
            do {
                let saved = try await form.submit(to: api)
                if isCurrent {
                    if form.channel == nil { presenter.didCreate(saved, on: api.baseURL.absoluteString) }
                    else { presenter.flow = nil }
                }
                await catalog?.refresh()
            } catch {
                failed = true
                session.error = error.localizedDescription
            }
            session.pending = false
            if failed, presenter.flow == submittedFlow, isCurrent {
                await Task.yield()
                guard presenter.flow == submittedFlow, isCurrent else { return }
                session.focus = submittedFocus
            }
        }
    }
}
