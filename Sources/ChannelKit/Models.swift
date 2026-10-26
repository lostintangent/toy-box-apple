import Foundation

public struct ProviderModel: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var provider: String
    public var providerName: String?
    public var supportedReasoningEfforts: [String]?
    public var supportedContextTiers: [ContextTier]?

    public struct ContextTier: Codable, Sendable {
        public var name: String
        public var tokenWindow: Int?
    }

    public var configuration: ModelConfiguration { .init(provider: provider, name: id) }
}

public struct ModelCatalog: Codable, Sendable {
    public var version: Int
    public var models: [ProviderModel]
    public var defaultModel: ModelConfiguration?
    public var provider: String?
}

public struct ChannelModelSelection: Sendable {
    public enum Scope: Equatable, Sendable {
        case channel, member
    }

    public let model: ModelConfiguration?
    public let scope: Scope
    private let openingModel: ModelConfiguration?
    private let catalog: ModelCatalog?
    private let provider: String?

    public init(model: ModelConfiguration?, openingModel: ModelConfiguration? = nil,
                catalog: ModelCatalog? = nil, provider: String? = nil, scope: Scope) {
        self.model = model
        self.openingModel = openingModel
        self.catalog = catalog
        self.provider = provider
        self.scope = scope
    }

    public var choices: [ProviderModel] {
        let constraint = catalog?.provider ?? provider
        return (catalog?.models ?? []).filter { constraint == nil || $0.provider == constraint }
    }

    public var isEnabled: Bool { scope == .member || !choices.isEmpty }
    public var key: String { model.map { "\($0.provider)/\($0.name)" } ?? "" }

    public var selected: ProviderModel? {
        choices.first { $0.provider == model?.provider && $0.id == model?.name }
    }

    public var retainedModel: ModelConfiguration? {
        guard let retained = model ?? (scope == .member ? openingModel : nil),
              !choices.contains(where: { $0.provider == retained.provider && $0.id == retained.name })
        else { return nil }
        return retained
    }

    public func selecting(_ key: String) -> ModelConfiguration? {
        if key.isEmpty, scope == .member { return nil }
        if let retainedModel, key == "\(retainedModel.provider)/\(retainedModel.name)" { return retainedModel }
        if let choice = choices.first(where: { "\($0.provider)/\($0.id)" == key }) {
            return model?.provider == choice.provider && model?.name == choice.id ? model : choice.configuration
        }
        return model
    }

    public var defaultModel: ModelConfiguration? {
        guard model == nil, scope == .channel, let catalog, let candidate = catalog.defaultModel,
              catalog.models.contains(where: { $0.id == candidate.name && $0.provider == candidate.provider }),
              provider == nil || candidate.provider == provider else { return nil }
        return candidate
    }
}
