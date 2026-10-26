import Foundation
import Testing
@testable import ChannelKit

struct ModelSelectionTests {
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

    @Test func catalogWireValuesStillRoundTripAfterMovingToTheDomain() throws {
        let data = Data(#"{"version":1,"models":[{"id":"first","name":"First","provider":"copilot","supportedReasoningEfforts":["high"],"supportedContextTiers":[{"name":"long","tokenWindow":200000}]}],"defaultModel":{"provider":"copilot","name":"first"},"provider":"copilot"}"#.utf8)
        let decoded = try JSONDecoder().decode(ModelCatalog.self, from: data)
        #expect(decoded.models.first?.supportedContextTiers?.first?.tokenWindow == 200_000)
        #expect(decoded.models.first?.configuration == decoded.defaultModel)
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded))
                == JSONDecoder().decode(JSONValue.self, from: data))
    }

    private func catalog() -> ModelCatalog {
        .init(version: 1, models: [
            .init(id: "first", name: "First", provider: "copilot"),
            .init(id: "second", name: "Second", provider: "copilot"),
            .init(id: "first", name: "Other First", provider: "other"),
        ], defaultModel: .init(provider: "copilot", name: "first"))
    }
}
