import ChannelClient
import ChannelKit
import SwiftUI
import Testing
@testable import ToyBoxUI

@MainActor
struct ModelSelectionFieldsTests {
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
