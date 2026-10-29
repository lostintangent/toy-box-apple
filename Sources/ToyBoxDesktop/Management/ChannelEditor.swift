import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ChannelEditor: View {
    @Environment(AppModel.self) private var app
    @ViewState private var channel: ChannelDetails?
    let store: ChannelStore?
    let api: ChannelAPI
    let presenter: ManagementPresenter
    @ViewState private var name: String
    @ViewState private var purpose: String
    @ViewState private var directory: String
    @ViewState private var model: ModelConfiguration?
    @ViewState private var isSaving = false
    @ViewState private var recovery = ChannelManagementWriteRecovery()
    @FocusState private var nameFocused: Bool

    init(channel: ChannelDetails?, store: ChannelStore?, api: ChannelAPI, presenter: ManagementPresenter) {
        _channel = ViewState(initialValue: channel)
        self.store = store
        self.api = api
        self.presenter = presenter
        _name = ViewState(initialValue: channel?.name ?? "")
        _purpose = ViewState(initialValue: channel?.purpose ?? "")
        _directory = ViewState(initialValue: channel?.directory ?? "")
        _model = ViewState(initialValue: channel?.model)
    }

    private var nextName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nextPurpose: String { purpose.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nextDirectory: String { directory.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameViolation: String? {
        ChannelValidation.channelNameError(nextName)
    }
    private var purposeViolation: String? {
        ChannelValidation.purposeError(nextPurpose)
    }
    private var directoryViolation: String? {
        channel == nil ? ChannelValidation.directoryError(nextDirectory) : nil
    }
    // An empty name or a missing lead model only disables the default button. The prompt and the
    // model section's footer already say why.
    private var isValid: Bool {
        !nextName.isEmpty && model != nil
            && nameViolation == nil && purposeViolation == nil && directoryViolation == nil
    }
    private var hasChanges: Bool {
        guard let channel else { return true }
        return nextName != channel.name || nextPurpose != (channel.purpose ?? "") || model != channel.model
    }
    private var canSave: Bool {
        isValid && hasChanges && !isSaving && !recovery.blocksWrites
            && (store == nil || store?.phase.isConnected == true)
    }

    var body: some View {
        ManagementSheetLayout(
            title: channel == nil ? "New Channel" : "Edit Channel",
            subtitle: channel == nil
                ? "The lead starts right away and adds specialists as needed."
                : nil
        ) {
            ManagementChannelMark()
        } fields: {
            Section {
                TextField("Name", text: $name, prompt: Text("Required"))
                    .focused($nameFocused)
                    .onSubmit(submit)
                    .accessibilityHint(nameViolation ?? "")
                    .accessibilityIdentifier("channel-name")
                ManagementLongTextField(
                    title: "Purpose",
                    prompt: "What should this team work toward? The lead reads this first.",
                    text: $purpose, lines: 3...6, violation: purposeViolation)
                    .onSubmit(submit)
            } footer: {
                if let violation = nameViolation ?? purposeViolation {
                    ManagementFooter(violation: violation)
                }
            }
            ModelSelectionFields(
                model: $model, api: api, provider: channel?.model.provider, allowsInheritance: false,
                title: "Lead model",
                help: [channel == nil
                       ? "A folder on the server. Leave it empty for a discussion-only channel."
                       : "Only the lead can change the directory. Model changes apply the next time the lead works."],
                violation: directoryViolation
            ) {
                if channel == nil {
                    TextField("Working directory", text: $directory, prompt: Text("Optional"))
                        .onSubmit(submit)
                        .accessibilityHint(directoryViolation ?? "")
                } else {
                    LabeledContent("Working directory") {
                        Text(directory.isEmpty ? "None" : directory)
                            .foregroundStyle(directory.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(directory)
                    }
                }
            }
        } notices: {
            ManagementConnectionNotice(store: store)
            if let error = recovery.error { ManagementError(message: error) }
            if let state = recovery.state {
                ManagementRecoveryNotice(
                    state: state,
                    reviewTitle: recovery.result?.state == nil ? nil : "Use Current Server Values",
                    onCheck: { Task { await checkCurrentState() } },
                    onReview: useCurrentServerValues)
            }
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
        guard canSave, let model else { return }
        isSaving = true
        recovery.clearError()
        Task {
            defer { isSaving = false }
            do {
                if let channel {
                    _ = try await api.editChannel(
                        id: channel.id,
                        changes: .init(name: nextName == channel.name ? nil : nextName,
                                       purpose: nextPurpose == (channel.purpose ?? "")
                                       ? nil : nextPurpose.isEmpty ? .clear : .set(nextPurpose),
                                       model: model == channel.model ? nil : model))
                    presenter.flow = nil
                } else {
                    let path = directory.trimmingCharacters(in: .whitespacesAndNewlines)
                    let created = try await api.createChannel(
                        .init(name: nextName, purpose: nextPurpose.isEmpty ? nil : nextPurpose,
                              directory: path.isEmpty ? nil : path, model: model))
                    presenter.didCreate(created)
                }
                await app.catalog?.refresh()
            } catch {
                if recovery.record(error) { await checkCurrentState() }
            }
        }
    }

    private func checkCurrentState() async {
        await recovery.check(catalog: app.catalog, channelId: channel?.id) { current in
            if current.channelWasDeleted {
                return "The channel is no longer present on the server. No further save is available."
            }
            if let channel = current.state?.channel {
                return "The server's current channel is \(channel.name). Your entries are preserved. Use Current Server Values replaces them with the refreshed name, purpose and model."
            }
            return "The channel list has been refreshed. Close this sheet and review the list before creating another channel. Your entries are preserved until you close the sheet."
        }
    }

    private func useCurrentServerValues() {
        guard let current = recovery.result?.state?.channel else { return }
        channel = ChannelDetails(current)
        name = current.name
        purpose = current.purpose ?? ""
        directory = current.directory ?? ""
        model = current.model
        recovery.finishReview()
    }
}
