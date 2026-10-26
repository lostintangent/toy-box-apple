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

    @Test func missingModelEndpointHasAnHonestCapabilityMessage() {
        let missing = ChannelAPIError.http(status: 404, message: "Channel not found.")
        #expect(ModelSelectionFields<EmptyView>.catalogErrorMessage(missing, memberScoped: false)
                == "Models aren't available on this server.")
        #expect(ModelSelectionFields<EmptyView>.catalogErrorMessage(missing, memberScoped: true)
                .contains("Channel not found."))
        let disconnected = ChannelAPIError.disconnected
        #expect(ModelSelectionFields<EmptyView>.catalogErrorMessage(disconnected, memberScoped: false)
                .contains(disconnected.localizedDescription))
    }
}
