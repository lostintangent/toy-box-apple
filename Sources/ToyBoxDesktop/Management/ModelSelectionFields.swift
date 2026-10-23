import ChannelClient
import ChannelKit
import SwiftUI

/// The model section of a management sheet: the model, its Reasoning and Context options when the
/// chosen model offers them, any rows the sheet adds, and a footer that explains the catalog.
struct ModelSelectionFields<ExtraRows: View>: View {
    @Binding var model: ModelConfiguration?
    let api: ChannelAPI
    let provider: String?
    let allowsInheritance: Bool
    var title = "Model"
    var memberScope: (channelId: String, agentId: String)?
    var help: [String] = []
    var violation: String?
    let extraRows: ExtraRows
    @ViewState private var catalog: ModelCatalog?
    @ViewState private var isLoading = true
    @ViewState private var error: (any Error)?
    @ViewState private var hasRequestedCatalog = false
    /// The model the sheet opened with, so a cleared override can be restored without a catalog.
    @ViewState private var initialModel: ModelConfiguration?

    init(model: Binding<ModelConfiguration?>, api: ChannelAPI, provider: String?, allowsInheritance: Bool,
         title: String = "Model", memberScope: (channelId: String, agentId: String)? = nil,
         help: [String] = [], violation: String? = nil, @ViewBuilder extraRows: () -> ExtraRows) {
        _model = model
        _initialModel = ViewState(initialValue: model.wrappedValue)
        self.api = api
        self.provider = provider
        self.allowsInheritance = allowsInheritance
        self.title = title
        self.memberScope = memberScope
        self.help = help
        self.violation = violation
        self.extraRows = extraRows()
    }

    private var choices: [ProviderModel] {
        let constraint = catalog?.provider ?? provider
        return (catalog?.models ?? []).filter { constraint == nil || $0.provider == constraint }
    }
    var isSelectionEnabled: Bool { allowsInheritance || !choices.isEmpty }
    private var selected: ProviderModel? {
        choices.first { $0.provider == model?.provider && $0.id == model?.name }
    }
    /// The current choice, or the original override after it was cleared, when the catalog doesn't list it.
    private var retainedModel: ModelConfiguration? {
        guard let retained = model ?? (allowsInheritance ? initialModel : nil),
              !choices.contains(where: { $0.provider == retained.provider && $0.id == retained.name })
        else { return nil }
        return retained
    }
    var selection: Binding<String> {
        Binding {
            model.map { "\($0.provider)/\($0.name)" } ?? ""
        } set: { key in
            if key.isEmpty, allowsInheritance { model = nil }
            else if let retainedModel, key == "\(retainedModel.provider)/\(retainedModel.name)" {
                if model != retainedModel { model = retainedModel }
            } else if let choice = choices.first(where: { "\($0.provider)/\($0.id)" == key }) {
                if model?.provider != choice.provider || model?.name != choice.id {
                    model = choice.configuration
                }
            }
        }
    }
    private var workspaceDefaultTitle: String {
        guard let inherited = catalog?.defaultModel else { return "Workspace Default" }
        let name = catalog?.models.first { $0.provider == inherited.provider && $0.id == inherited.name }?.name
        return "Workspace Default (\(name ?? inherited.name))"
    }
    private var footerHelp: [String] {
        var lines: [String] = []
        if let error {
            lines.append(Self.catalogErrorMessage(error, memberScoped: memberScope != nil))
        } else if catalog != nil, choices.isEmpty {
            lines.append("No models are available for this provider.")
        }
        if allowsInheritance, memberScope != nil, catalog != nil, catalog?.defaultModel == nil {
            lines.append("No compatible workspace default is available. Clearing the override keeps this agent's existing provider and model.")
        }
        return lines + help
    }

    var body: some View {
        Section {
            if isLoading {
                LabeledContent(title) {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading models")
                }
            } else if error != nil {
                LabeledContent(title) {
                    HStack(spacing: 8) {
                        // A member's override stays clearable without a catalog, as the spec requires.
                        if retainedModel != nil {
                            picker.labelsHidden().fixedSize()
                        } else {
                            Text("Couldn't Load").foregroundStyle(.secondary)
                        }
                        Button("Retry") { Task { await load() } }
                            .controlSize(.small)
                    }
                }
            } else {
                picker.disabled(!isSelectionEnabled)
                if let selected {
                    optionPicker("Reasoning", key: "reasoningEffort",
                                 values: selected.supportedReasoningEfforts ?? [])
                    optionPicker("Context", key: "contextTier",
                                 values: selected.supportedContextTiers?.map(\.name) ?? [])
                }
            }
            extraRows
        } footer: {
            if violation != nil || !footerHelp.isEmpty {
                ManagementFooter(help: footerHelp, violation: violation)
            }
        }
        .task {
            // A Section may hand its modifiers to each row, so only the first appearance loads.
            guard !hasRequestedCatalog else { return }
            hasRequestedCatalog = true
            await load()
        }
    }

    private var picker: some View {
        Picker(title, selection: selection) {
            if allowsInheritance {
                Text(workspaceDefaultTitle).tag("")
            }
            if let retainedModel {
                Text(error == nil ? "\(retainedModel.name) (current, unavailable)" : "\(retainedModel.name) (current)")
                    .tag("\(retainedModel.provider)/\(retainedModel.name)")
            } else if model == nil, !allowsInheritance {
                Text("Choose a Model").tag("")
            }
            ForEach(choices, id: \.selfKey) { choice in
                Text("\(choice.name) · \(choice.providerName ?? choice.provider)")
                    .tag(choice.selfKey)
            }
        }
    }

    @ViewBuilder
    private func optionPicker(_ label: String, key: String, values: [String]) -> some View {
        if !values.isEmpty {
            let current = model?.options[key]?.string ?? ""
            Picker(label, selection: Binding(
                get: { model?.options[key]?.string ?? "" },
                set: { value in
                    if value.isEmpty { model?.options.removeValue(forKey: key) }
                    else { model?.options[key] = .string(value) }
                })) {
                    Text("Default").tag("")
                    if !current.isEmpty, !values.contains(current) {
                        Text("\(current) (current)").tag(current)
                    }
                    ForEach(values, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result: ModelCatalog
            if let memberScope {
                result = try await api.memberModels(channelId: memberScope.channelId,
                                                    agentId: memberScope.agentId)
            } else {
                result = try await api.models()
            }
            catalog = result
            if model == nil, !allowsInheritance,
               let defaultModel = result.defaultModel,
               result.models.contains(where: {
                   $0.id == defaultModel.name && $0.provider == defaultModel.provider
               }), provider == nil || defaultModel.provider == provider {
                model = defaultModel
            }
        } catch {
            self.error = error
        }
    }

    static func catalogErrorMessage(_ error: any Error, memberScoped: Bool) -> String {
        if !memberScoped, case ChannelAPIError.http(status: 404, message: _) = error {
            return "Models aren't available on this server."
        }
        return "Models could not be loaded. \(error.localizedDescription)"
    }
}

extension ModelSelectionFields where ExtraRows == EmptyView {
    init(model: Binding<ModelConfiguration?>, api: ChannelAPI, provider: String?, allowsInheritance: Bool,
         title: String = "Model", memberScope: (channelId: String, agentId: String)? = nil,
         help: [String] = [], violation: String? = nil) {
        self.init(model: model, api: api, provider: provider, allowsInheritance: allowsInheritance,
                  title: title, memberScope: memberScope, help: help, violation: violation) { EmptyView() }
    }
}

private extension ProviderModel {
    var selfKey: String { "\(provider)/\(id)" }
}
