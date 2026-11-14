import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ChannelEditor: View {
    @Environment(AppModel.self) private var app
    let store: ChannelStore?
    /// The channel's server, or the one New Channel creates on, which its Server menu changes.
    let catalog: ChannelCatalogStore
    @Bindable var presenter: ManagementPresenter
    @FocusState private var nameFocused: Bool

    private var form: ChannelForm { presenter.channelForm }
    private var isSaving: Bool { presenter.isPending }
    private var serverSelection: Binding<String> {
        Binding { catalog.api.baseURL.absoluteString } set: { presenter.flow = .newChannel(server: $0) }
    }
    private var channel: ChannelDetails? { form.channel }
    private var canSave: Bool {
        form.isSubmittable && !isSaving && (store == nil || store?.phase.isConnected == true)
    }

    var body: some View {
        ManagementSheetLayout(
            title: channel == nil ? "New Channel" : "Edit Channel",
            subtitle: channel == nil
                ? "The lead starts right away and adds specialists as needed."
                : nil
        ) {
            ManagementChannelMark(channelId: channel?.id, catalog: catalog)
        } fields: {
            if channel == nil, app.servers.shown.count > 1 {
                Section {
                    Picker("Server", selection: serverSelection) {
                        ForEach(app.servers.shown, id: \.api.baseURL) { catalog in
                            Text(catalog.name).tag(catalog.api.baseURL.absoluteString)
                        }
                    }
                }
            }
            Section {
                TextField("Name", text: $presenter.channelForm.name, prompt: Text("Required"))
                    .focused($nameFocused)
                    .onSubmit(submit)
                    .accessibilityHint(form.nameViolation ?? "")
                    .accessibilityIdentifier("channel-name")
                ManagementLongTextField(
                    title: "Purpose",
                    prompt: "What should this team work toward? The lead reads this first.",
                    text: $presenter.channelForm.purpose, lines: 3...6, violation: form.purposeViolation)
                    .onSubmit(submit)
            } footer: {
                if let violation = form.nameViolation ?? form.purposeViolation {
                    ManagementFooter(violation: violation)
                }
            }
            ModelSelectionFields(
                model: $presenter.channelForm.model, openingModel: channel?.model, api: catalog.api,
                provider: channel?.model.provider, allowsInheritance: false,
                title: "Lead model",
                help: [channel == nil
                       ? "A folder on the server. Leave it empty for a discussion-only channel."
                       : "Only the lead can change the directory. Model changes apply the next time the lead works."],
                violation: form.directoryViolation
            ) {
                if channel == nil {
                    TextField("Working directory", text: $presenter.channelForm.directory, prompt: Text("Optional"))
                        .onSubmit(submit)
                        .accessibilityHint(form.directoryViolation ?? "")
                } else {
                    LabeledContent("Working directory") {
                        Text(form.directory.isEmpty ? "None" : form.directory)
                            .foregroundStyle(form.directory.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(form.directory)
                    }
                }
            }
            // Another server's models load fresh.
            .id(ObjectIdentifier(catalog))
        } notices: {
            ManagementConnectionNotice(store: store)
            if let error = presenter.error { ManagementError(message: error) }
        } buttons: {
            Spacer()
            Button("Cancel", role: .cancel) { presenter.flow = nil }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button(channel == nil
                   ? (isSaving ? "Creating\u{2026}" : "Create Channel")
                   : (isSaving ? "Saving\u{2026}" : "Save")) { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .onAppear { nameFocused = true }
        .background {
            Button("Submit") { submit() }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
                .disabled(!canSave)
        }
    }

    private func submit() {
        guard canSave else { return }
        Task { await presenter.save(on: catalog) }
    }
}
