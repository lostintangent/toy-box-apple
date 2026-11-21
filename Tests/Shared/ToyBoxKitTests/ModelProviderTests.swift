import Foundation
import Testing
@testable import ToyBoxKit

struct ModelProviderTests {
    @Test func onlyAnEnabledReadyProviderReadsUsage() {
        let ready = ModelProvider(id: "codex", name: "OpenAI Codex", status: .ready, enabled: true)
        #expect(ready.readsUsage)
        #expect(!ModelProvider(id: "codex", name: "OpenAI Codex", status: .ready, enabled: false).readsUsage)
        #expect(!ModelProvider(id: "gemini", name: "Gemini", status: .signedOut, enabled: true).readsUsage)
        #expect(!ModelProvider(id: "claude", name: "Claude Agent", status: .failed, error: "offline",
                               enabled: true).readsUsage)
        #expect(!ModelProvider(id: "missing", name: "Missing", status: .unavailable, enabled: false).readsUsage)
    }

    @Test func aLimitDecodesEpochMillisecondsAsADate() throws {
        let limit = try JSONDecoder().decode(ModelProviderLimit.self, from: Data(#"""
            {"name":"Weekly","usedPercent":10,"resetsAt":1795568399982}
            """#.utf8))
        #expect(limit.name == "Weekly")
        #expect(limit.usedPercent == 10)
        #expect(limit.resetsAt == Date(timeIntervalSince1970: 1_795_568_399.982))
        let encoded = try JSONEncoder().encode(limit)
        let roundTrip = try JSONDecoder().decode(ModelProviderLimit.self, from: encoded)
        #expect(roundTrip == limit)
    }

    @Test func aSubscriptionDecodesEmptyLimitsAndAnOptionalReset() throws {
        let subscription = try JSONDecoder().decode(ModelProviderSubscription.self, from: Data(#"""
            {"plan":"enterprise","limits":[{"name":"Weekly","usedPercent":0}]}
            """#.utf8))
        #expect(subscription.plan == "enterprise")
        #expect(subscription.limits == [.init(name: "Weekly", usedPercent: 0)])
    }

    @Test func theProviderListKeepsTheServersOrderAndStatuses() throws {
        let list = try JSONDecoder().decode(ModelProviderList.self, from: Data(#"""
            {"providers":[
              {"id":"copilot","name":"GitHub Copilot","status":"ready","version":"1.0.114","enabled":true},
              {"id":"gemini","name":"Gemini","status":"signedOut","enabled":true},
              {"id":"broken","name":"Broken","status":"failed","error":"CLI exited 1.","enabled":true},
              {"id":"gone","name":"Gone","status":"unavailable","enabled":false}
            ]}
            """#.utf8))
        #expect(list.providers.map(\.id) == ["copilot", "gemini", "broken", "gone"])
        #expect(list.providers.map(\.status) == [.ready, .signedOut, .failed, .unavailable])
        #expect(list.providers[2].error == "CLI exited 1.")
        #expect(list.providers[3].version == nil)
    }
}
