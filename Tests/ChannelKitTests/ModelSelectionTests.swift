import Foundation
import Testing
@testable import ChannelKit

struct ModelSelectionTests {
    @Test func catalogDecodesDefaultReasoningAndContextWindows() throws {
        let model = try JSONDecoder().decode(ProviderModel.self, from: Data(#"""
            {"id":"model","name":"Model","provider":"copilot",
             "supportedReasoningEfforts":["low","medium","xhigh"],"defaultReasoningEffort":"medium",
             "supportedContextTiers":[{"name":"default","tokenWindow":200000},
                                      {"name":"long_context","tokenWindow":1000000}]}
            """#.utf8))
        #expect(model.defaultReasoningEffort == "medium")
        #expect(model.supportedContextTiers?.map(\.tokenWindow) == [200_000, 1_000_000])
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(model))
        #expect(encoded["defaultReasoningEffort"] == .string("medium"))
    }

    @Test func reasoningResolvesTheSupportedRequestThenDeclaredDefaultThenFirstValue() {
        var model = ProviderModel(id: "model", name: "Model", provider: "copilot",
                                  supportedReasoningEfforts: ["low", "medium", "xhigh"],
                                  defaultReasoningEffort: "medium")
        #expect(model.resolvedReasoningEffort(requested: "xhigh") == "xhigh")
        #expect(model.resolvedReasoningEffort(requested: "unsupported") == "medium")
        #expect(model.resolvedReasoningEffort(requested: nil) == "medium")
        #expect(model.resolvedReasoningEffort(requested: "") == "medium")
        model.defaultReasoningEffort = nil
        #expect(model.resolvedReasoningEffort(requested: "unsupported") == "low")
        #expect(model.resolvedReasoningEffort(requested: nil) == "low")
        model.defaultReasoningEffort = "declared-default"
        #expect(model.resolvedReasoningEffort(requested: nil) == "declared-default")
        model.supportedReasoningEfforts = []
        #expect(model.resolvedReasoningEffort(requested: nil) == "declared-default")
        model.defaultReasoningEffort = nil
        #expect(model.resolvedReasoningEffort(requested: nil) == nil)
    }

    @Test func contextResolvesOnlyASupportedRequestOrTheFirstTier() {
        var model = ProviderModel(id: "model", name: "Model", provider: "copilot",
                                  supportedContextTiers: [
                                    .init(name: "default", tokenWindow: 200_000),
                                    .init(name: "long_context", tokenWindow: 1_000_000)
                                  ])
        #expect(model.resolvedContextTier(requested: "long_context") == "long_context")
        #expect(model.resolvedContextTier(requested: "unsupported") == "default")
        #expect(model.resolvedContextTier(requested: nil) == "default")
        #expect(model.resolvedContextTier(requested: "") == "default")
        model.supportedContextTiers?.reverse()
        #expect(model.resolvedContextTier(requested: nil) == "long_context")
        model.supportedContextTiers = nil
        #expect(model.resolvedContextTier(requested: "default") == nil)
    }

    @Test func clearingMemberModelDoesNotRequireCatalogChoicesOrACompatibleDefault() {
        let model = ModelConfiguration(provider: "copilot", name: "existing-model",
                                       options: ["reasoningEffort": .string("high")])
        let member = ChannelModelSelection(model: model, openingModel: model, provider: "copilot", scope: .member)
        #expect(member.isEnabled)
        #expect(member.key == "copilot/existing-model")
        #expect(member.selecting("") == nil)
        let cleared = ChannelModelSelection(model: member.selecting(""), openingModel: model,
                                             provider: "copilot", scope: .member)
        #expect(cleared.key == "")
        #expect(cleared.retainedModel == model)
        #expect(cleared.selecting("copilot/existing-model") == model)
        #expect(!ChannelModelSelection(model: nil, scope: .channel).isEnabled)
        #expect(ChannelModelSelection(model: nil, scope: .member).isEnabled)
    }

    @Test func choosingTheSameAvailableModelKeepsEveryOption() {
        let model = ModelConfiguration(provider: "copilot", name: "first",
                                       options: ["contextTier": .string("long")])
        let selection = ChannelModelSelection(model: model, catalog: catalog(), scope: .member)
        #expect(selection.selected?.id == "first")
        #expect(selection.retainedModel == nil)
        #expect(selection.selecting("copilot/first") == model)
        #expect(selection.selecting("copilot/second") == .init(provider: "copilot", name: "second"))
        #expect(selection.selecting("unknown/model") == model)
        #expect(ChannelModelSelection(model: model, catalog: catalog(), scope: .channel).selecting("") == model)
    }

    @Test func catalogProviderTakesPrecedenceWithoutChangingDefaultEligibility() {
        var catalog = catalog()
        catalog.provider = "other"
        let selection = ChannelModelSelection(model: nil, catalog: catalog, provider: "copilot", scope: .channel)
        #expect(selection.choices.map(\.provider) == ["other"])
        #expect(selection.defaultModel == catalog.defaultModel)
        #expect(ChannelModelSelection(model: nil, catalog: catalog, provider: "incompatible", scope: .channel).defaultModel == nil)
        catalog.defaultModel = .init(provider: "copilot", name: "missing")
        #expect(ChannelModelSelection(model: nil, catalog: catalog, scope: .channel).defaultModel == nil)
    }

    @Test func membersNeverReceiveAnAutomaticOverrideAndExistingChannelModelsAreNotReplaced() {
        let catalog = catalog()
        #expect(ChannelModelSelection(model: nil, catalog: catalog, scope: .member).defaultModel == nil)
        #expect(ChannelModelSelection(model: nil, catalog: catalog, scope: .member).selecting("") == nil)
        #expect(ChannelModelSelection(model: nil, catalog: catalog, scope: .channel).defaultModel == catalog.defaultModel)
        #expect(ChannelModelSelection(model: .init(provider: "copilot", name: "unavailable"),
                                      catalog: catalog, scope: .channel).defaultModel == nil)
    }

    private func catalog() -> ModelCatalog {
        .init(version: 1, models: [
            .init(id: "first", name: "First", provider: "copilot"),
            .init(id: "second", name: "Second", provider: "copilot"),
            .init(id: "first", name: "Other First", provider: "other"),
        ], defaultModel: .init(provider: "copilot", name: "first"))
    }
}
