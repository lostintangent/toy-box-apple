import ChannelClient
import ChannelKit
import SwiftUI
import Testing
@testable import ToyBoxUI

@MainActor
struct ModelSelectionFieldsTests {
    @Test func realContextChoicesUseCompactWindowsWithoutAnEmptyDefault() throws {
        let model = try optionModel()
        let choices = ModelOptionChoice.context(try #require(model.supportedContextTiers), current: nil)
        #expect(choices.map(\.id) == ["default", "long_context", "extended", "binary", "fractional"])
        #expect(choices.map(\.label) == ["200K", "1M", "936K", "1.05M", "250.25K"])
        #expect(!choices.contains { $0.id.isEmpty || $0.label == "Default" })
        #expect(ModelOptionChoice.context([], current: "old").isEmpty)
    }

    @Test func reasoningNamesMatchThePaneWithoutLowercasingExistingCapitals() {
        let choices = ModelOptionChoice.reasoning(
            ["low", "xhigh", "XHIGH", "extra-high", "adaptive_reasoning", "  mixed CASE  "], current: nil)
        #expect(choices.map(\.label) ==
                ["Low", "Extra High", "Extra High", "Extra High", "Adaptive Reasoning", "Mixed CASE"])
        #expect(choices.count == 6)
        #expect(!choices.contains { $0.id.isEmpty })
        #expect(ModelOptionChoice.reasoning([], current: "old").isEmpty)
        func label(_ effort: JSONValue?) -> String? {
            ModelConfiguration(provider: "copilot", name: "model",
                               options: effort.map { ["reasoningEffort": $0] } ?? [:]).reasoningLabel
        }
        #expect(label(.string("xhigh")) == "Extra High")
        #expect(label(.string("adaptive_reasoning")) == "Adaptive Reasoning")
        #expect(label(.string("")) == nil && label(nil) == nil && label(.bool(true)) == nil)
    }

    @Test func unknownContextWindowsKeepTheTierNameAndUnsupportedValuesKeepTheirCurrentRow() throws {
        let model = try JSONDecoder().decode(ProviderModel.self, from: Data(#"""
            {"id":"model","name":"Model","provider":"copilot",
             "supportedContextTiers":[{"name":"default"},{"name":"long_context"}]}
            """#.utf8))
        let choices = ModelOptionChoice.context(try #require(model.supportedContextTiers), current: "legacy")
        #expect(choices.map(\.id) == ["legacy", "default", "long_context"])
        #expect(choices.map(\.label) == ["legacy (current)", "Default", "Long Context"])
        let reasoning = ModelOptionChoice.reasoning(["low", "high"], current: "legacy")
        #expect(reasoning.map(\.label) == ["legacy (current)", "Low", "High"])
        #expect(ModelOptionChoice.reasoning(["low", "high"], current: "high").count == 2)
    }

    @Test(arguments: [false, true])
    func resolvingAnOpeningModelNeverWritesOrDirtiesIt(unsupported: Bool) throws {
        let api = try ChannelAPI(serverURL: "https://fixture.example")
        let catalogModel = try optionModel()
        var options: [String: JSONValue] = ["future": .object(["enabled": .bool(true)])]
        if unsupported {
            options["reasoningEffort"] = .string("legacy-reasoning")
            options["contextTier"] = .string("legacy-context")
        }
        let opening = ModelConfiguration(provider: "copilot", name: "model", options: options)
        var model: ModelConfiguration? = opening
        var writes = 0
        let fields = ModelSelectionFields(
            model: Binding(get: { model }, set: { model = $0; writes += 1 }),
            openingModel: opening, api: api, provider: nil, allowsInheritance: false)
        let reasoning = fields.optionSelection(
            key: "reasoningEffort",
            resolvedValue: catalogModel.resolvedReasoningEffort(requested: options["reasoningEffort"]?.string))
        let context = fields.optionSelection(
            key: "contextTier",
            resolvedValue: catalogModel.resolvedContextTier(requested: options["contextTier"]?.string))
        #expect(reasoning.wrappedValue == (unsupported ? "legacy-reasoning" : "medium"))
        #expect(context.wrappedValue == (unsupported ? "legacy-context" : "default"))
        reasoning.wrappedValue = reasoning.wrappedValue
        context.wrappedValue = context.wrappedValue
        #expect(model == opening)
        #expect(writes == 0)
        reasoning.wrappedValue = "xhigh"
        #expect(model?.options["reasoningEffort"] == .string("xhigh"))
        #expect(model?.options["contextTier"] == options["contextTier"])
        #expect(model?.options["future"] == options["future"])
        #expect(writes == 1)
        context.wrappedValue = "long_context"
        #expect(model?.options["contextTier"] == .string("long_context"))
        #expect(model?.options["reasoningEffort"] == .string("xhigh"))
        #expect(model?.options["future"] == options["future"])
        #expect(writes == 2)
    }

    @Test func emptyLegacyOptionsResolveWithoutRewritingTheStoredConfiguration() throws {
        let api = try ChannelAPI(serverURL: "https://fixture.example")
        let opening = ModelConfiguration(provider: "copilot", name: "model",
                                         options: ["reasoningEffort": .string(""), "contextTier": .string("")])
        var model: ModelConfiguration? = opening
        var writes = 0
        let fields = ModelSelectionFields(
            model: Binding(get: { model }, set: { model = $0; writes += 1 }),
            api: api, provider: nil, allowsInheritance: false)
        let reasoning = fields.optionSelection(key: "reasoningEffort", resolvedValue: "medium")
        let context = fields.optionSelection(key: "contextTier", resolvedValue: "default")
        #expect(reasoning.wrappedValue == "medium")
        #expect(context.wrappedValue == "default")
        reasoning.wrappedValue = "medium"
        context.wrappedValue = "default"
        #expect(model == opening)
        #expect(writes == 0)
    }

    private func optionModel() throws -> ProviderModel {
        try JSONDecoder().decode(ProviderModel.self, from: Data(#"""
            {"id":"model","name":"Model","provider":"copilot",
             "supportedReasoningEfforts":["low","medium","xhigh"],"defaultReasoningEffort":"medium",
             "supportedContextTiers":[{"name":"default","tokenWindow":200000},
                                      {"name":"long_context","tokenWindow":1000000},
                                      {"name":"extended","tokenWindow":936000},
                                      {"name":"binary","tokenWindow":1048576},
                                      {"name":"fractional","tokenWindow":250250}]}
            """#.utf8))
    }

    @Test func modelBindingRetainsUnavailableOptionsAndAvoidsUnchangedWrites() throws {
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        let opening = ModelConfiguration(provider: "copilot", name: "existing-model",
                                         options: ["reasoningEffort": .string("high")])
        var model: ModelConfiguration? = opening
        var writes = 0
        let fields = ModelSelectionFields(
            model: Binding(get: { model }, set: { model = $0; writes += 1 }),
            api: api, provider: "copilot", allowsInheritance: true)
        fields.selection.wrappedValue = "copilot/existing-model"
        fields.selection.wrappedValue = "unknown/model"
        #expect(model == opening)
        #expect(writes == 0)
        fields.selection.wrappedValue = ""
        fields.selection.wrappedValue = ""
        #expect(model == nil)
        #expect(writes == 1)
        fields.selection.wrappedValue = "copilot/existing-model"
        #expect(model == opening)
        #expect(writes == 2)
    }

    @Test func missingModelEndpointsShowUnavailableWithoutRetryAndKeepScopedErrorDetails() {
        let missing = ChannelAPIError.http(status: 404, message: "Channel not found.")
        let global = ModelSelectionFields<EmptyView>.catalogErrorPresentation(missing, memberScoped: false)
        #expect(global.title == "Not Available")
        #expect(global.message == "Models aren't available on this server.")
        #expect(!global.canRetry)
        let scoped = ModelSelectionFields<EmptyView>.catalogErrorPresentation(missing, memberScoped: true)
        #expect(scoped.title == "Not Available")
        #expect(scoped.message.contains("Channel not found."))
        #expect(!scoped.canRetry)
    }

    @Test func catalogLoadFailuresKeepTheirReasonAndRetry() {
        for error in [ChannelAPIError.disconnected, .http(status: 500, message: "Please try again."),
                      .http(status: 403, message: "Forbidden.")] {
            for memberScoped in [false, true] {
                let failure = ModelSelectionFields<EmptyView>.catalogErrorPresentation(error, memberScoped: memberScoped)
                #expect(failure.title == "Couldn't Load")
                #expect(failure.message.contains(error.localizedDescription))
                #expect(failure.canRetry)
            }
        }
    }

    @Test func reconstructionKeepsTheUnavailableOpeningOverrideAfterClearingIt() throws {
        let api = try ChannelAPI(serverURL: "https://fixture.example")
        let original = ModelConfiguration(provider: "copilot", name: "unavailable",
                                          options: ["contextTier": .string("long_context")])
        var model: ModelConfiguration? = original
        let binding = Binding(get: { model }, set: { model = $0 })
        let first = ModelSelectionFields(model: binding, openingModel: original, api: api,
                                         provider: "copilot", allowsInheritance: true)
        first.selection.wrappedValue = ""
        #expect(model == nil)
        let rebuilt = ModelSelectionFields(model: binding, openingModel: original, api: api,
                                           provider: "copilot", allowsInheritance: true)
        rebuilt.selection.wrappedValue = "copilot/unavailable"
        #expect(model == original)
    }

    @Test func anExplicitlyInheritedOpeningDoesNotCaptureASubsequentOverride() throws {
        let api = try ChannelAPI(serverURL: "https://fixture.example")
        var model: ModelConfiguration? = ModelConfiguration(provider: "copilot", name: "later-choice")
        let binding = Binding(get: { model }, set: { model = $0 })
        let rebuilt = ModelSelectionFields(model: binding, openingModel: nil, api: api,
                                           provider: "copilot", allowsInheritance: true)
        rebuilt.selection.wrappedValue = ""
        #expect(model == nil)
        rebuilt.selection.wrappedValue = "copilot/later-choice"
        #expect(model == nil)
    }
}
