import ChannelClient
import ChannelKit
import SwiftUI

private typealias ViewState = SwiftUI.State

/// The model section of a management sheet: the model, its Reasoning and Context options when the
/// chosen model offers them, any rows the sheet adds, and a footer that explains the catalog.
public struct ModelSelectionFields<ExtraRows: View>: View {
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

    public init(model: Binding<ModelConfiguration?>, api: ChannelAPI, provider: String?, allowsInheritance: Bool,
         title: String = "Model", memberScope: (channelId: String, agentId: String)? = nil,
         help: [String] = [], violation: String? = nil, @ViewBuilder extraRows: () -> ExtraRows) {
        self.init(model: model, openingModel: model.wrappedValue, api: api, provider: provider,
                  allowsInheritance: allowsInheritance, title: title, memberScope: memberScope,
                  help: help, violation: violation, extraRows: extraRows)
    }

    /// Retains the original override across reconstruction, including an explicitly inherited nil.
    public init(model: Binding<ModelConfiguration?>, openingModel: ModelConfiguration?,
         api: ChannelAPI, provider: String?, allowsInheritance: Bool,
         title: String = "Model", memberScope: (channelId: String, agentId: String)? = nil,
         help: [String] = [], violation: String? = nil, @ViewBuilder extraRows: () -> ExtraRows) {
        _model = model
        _initialModel = ViewState(initialValue: openingModel)
        self.api = api
        self.provider = provider
        self.allowsInheritance = allowsInheritance
        self.title = title
        self.memberScope = memberScope
        self.help = help
        self.violation = violation
        self.extraRows = extraRows()
    }

    private var selectionPolicy: ChannelModelSelection {
        ChannelModelSelection(model: model, openingModel: initialModel, catalog: catalog,
                              provider: provider, scope: allowsInheritance ? .member : .channel)
    }
    var selection: Binding<String> {
        Binding {
            selectionPolicy.key
        } set: { key in
            let selected = selectionPolicy.selecting(key)
            if model != selected { model = selected }
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
            lines.append(Self.catalogErrorPresentation(error, memberScoped: memberScope != nil).message)
        } else if catalog != nil, selectionPolicy.choices.isEmpty {
            lines.append("No models are available for this provider.")
        }
        if allowsInheritance, memberScope != nil, catalog != nil, catalog?.defaultModel == nil {
            lines.append("No compatible workspace default is available. Clearing the override keeps this agent's existing provider and model.")
        }
        return lines + help
    }

    public var body: some View {
        Section {
            if isLoading {
                LabeledContent(title) {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading models")
                }
            } else if let error {
                let failure = Self.catalogErrorPresentation(error, memberScoped: memberScope != nil)
                LabeledContent(title) {
                    HStack(spacing: 8) {
                        // A member's override stays clearable without a catalog, as the spec requires.
                        if selectionPolicy.retainedModel != nil {
                            picker.labelsHidden().fixedSize()
                        }
                        if selectionPolicy.retainedModel == nil || !failure.canRetry {
                            Text(failure.title)
                                #if os(iOS)
                                .foregroundStyle(ChannelInk.secondary)
                                #else
                                .foregroundStyle(.secondary)
                                #endif
                        }
                        if failure.canRetry {
                            Button {
                                Task { await load() }
                            } label: {
                                Text("Retry")
                                    #if os(iOS)
                                    .foregroundStyle(Color.primary)
                                    #endif
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } else {
                picker.disabled(!selectionPolicy.isEnabled)
                if let selected = selectionPolicy.selected {
                    optionPicker("Reasoning", key: "reasoningEffort",
                                 choices: ModelOptionChoice.reasoning(
                                    selected.supportedReasoningEfforts ?? [],
                                    current: model?.options["reasoningEffort"]?.string),
                                 resolvedValue: selected.resolvedReasoningEffort(
                                    requested: model?.options["reasoningEffort"]?.string))
                    optionPicker("Context", key: "contextTier",
                                 choices: ModelOptionChoice.context(
                                    selected.supportedContextTiers ?? [],
                                    current: model?.options["contextTier"]?.string),
                                 resolvedValue: selected.resolvedContextTier(
                                    requested: model?.options["contextTier"]?.string))
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
            if let retainedModel = selectionPolicy.retainedModel {
                Text(error == nil ? "\(retainedModel.name) (current, unavailable)" : "\(retainedModel.name) (current)")
                    .tag("\(retainedModel.provider)/\(retainedModel.name)")
            } else if model == nil, !allowsInheritance {
                Text("Choose a Model").tag("")
            }
            ForEach(selectionPolicy.choices, id: \.selfKey) { choice in
                Text("\(choice.name) · \(choice.providerName ?? choice.provider)")
                    .tag(choice.selfKey)
            }
        }
    }

    func optionSelection(key: String, resolvedValue: String?) -> Binding<String> {
        func displayedValue() -> String {
            // An unsupported stored value stays selected in its retained current row.
            if let stored = model?.options[key]?.string, !stored.isEmpty { return stored }
            return resolvedValue ?? ""
        }
        return Binding(get: displayedValue, set: { value in
            if value != displayedValue() { model?.options[key] = .string(value) }
        })
    }

    @ViewBuilder
    private func optionPicker(_ label: String, key: String, choices: [ModelOptionChoice],
                              resolvedValue: String?) -> some View {
        if !choices.isEmpty {
            Picker(label, selection: optionSelection(key: key, resolvedValue: resolvedValue)) {
                ForEach(choices) { Text($0.label).tag($0.id) }
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
            if let defaultModel = selectionPolicy.defaultModel {
                model = defaultModel
            }
        } catch {
            self.error = error
        }
    }

    static func catalogErrorPresentation(_ error: any Error, memberScoped: Bool)
        -> (title: String, message: String, canRetry: Bool) {
        if case ChannelAPIError.http(status: 404, message: _) = error {
            let message = memberScoped
                ? "Models aren't available. \(error.localizedDescription)"
                : "Models aren't available on this server."
            return ("Not Available", message, false)
        }
        return ("Couldn't Load", "Models could not be loaded. \(error.localizedDescription)", true)
    }
}

extension ModelSelectionFields where ExtraRows == EmptyView {
    public init(model: Binding<ModelConfiguration?>, openingModel: ModelConfiguration?,
         api: ChannelAPI, provider: String?, allowsInheritance: Bool,
         title: String = "Model", memberScope: (channelId: String, agentId: String)? = nil,
         help: [String] = [], violation: String? = nil) {
        self.init(model: model, openingModel: openingModel, api: api, provider: provider,
                  allowsInheritance: allowsInheritance, title: title, memberScope: memberScope,
                  help: help, violation: violation) { EmptyView() }
    }

    public init(model: Binding<ModelConfiguration?>, api: ChannelAPI, provider: String?, allowsInheritance: Bool,
         title: String = "Model", memberScope: (channelId: String, agentId: String)? = nil,
         help: [String] = [], violation: String? = nil) {
        self.init(model: model, api: api, provider: provider, allowsInheritance: allowsInheritance,
                  title: title, memberScope: memberScope, help: help, violation: violation) { EmptyView() }
    }
}

private extension ProviderModel {
    var selfKey: String { "\(provider)/\(id)" }
}

extension ModelConfiguration {
    /// The requested reasoning effort in Edit Agent's words, such as "Extra High", or nil when unset.
    public var reasoningLabel: String? {
        guard let effort = options["reasoningEffort"]?.string, !effort.isEmpty else { return nil }
        return ModelOptionChoice.reasoningLabel(effort)
    }
}

struct ModelOptionChoice: Equatable, Identifiable {
    let id: String
    let label: String

    static func reasoning(_ values: [String], current: String?) -> [Self] {
        retaining(current, in: values.map { .init(id: $0, label: reasoningLabel($0)) })
    }

    static func context(_ tiers: [ProviderModel.ContextTier], current: String?) -> [Self] {
        retaining(current, in: tiers.map { tier in
            let label = tier.tokenWindow.map {
                $0.formatted(.number.notation(.compactName).precision(.fractionLength(0...2))
                    .locale(Locale(identifier: "en_US")))
            } ?? reasoningLabel(tier.name)
            return .init(id: tier.name, label: label)
        })
    }

    private static func retaining(_ current: String?, in choices: [Self]) -> [Self] {
        guard !choices.isEmpty, let current, !current.isEmpty,
              !choices.contains(where: { $0.id == current }) else { return choices }
        return [.init(id: current, label: "\(current) (current)")] + choices
    }

    static func reasoningLabel(_ value: String) -> String {
        let value = value.lowercased() == "xhigh" ? "Extra High" : value
        return value.split { $0.isWhitespace || $0 == "_" || $0 == "-" }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

public struct ManagementFooter: View {
    let help: [String]
    let violation: String?

    public init(help: [String] = [], violation: String? = nil) {
        self.help = help
        self.violation = violation
    }

    public var body: some View {
        Group {
            if let violation {
                Label {
                    Text(violation)
                        #if os(iOS)
                        .foregroundStyle(Color.primary)
                        #endif
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
            } else if !help.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(help, id: \.self) { Text($0) }
                }
            }
        }
        #if os(iOS)
        .font(.footnote)
        .foregroundStyle(ChannelInk.secondary)
        #else
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        #endif
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
