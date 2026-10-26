import ChannelClient
import ChannelKit
import Foundation
import Testing
@testable import ToyBoxMobile

@Suite("Mobile Overview")
@MainActor
struct OverviewTests {
    @Test func artifactFactoryRetainsTheStoreSessionAndClosesAReplacedStore() throws {
        let suite = "mobile-overview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:], defaults: defaults)
        let api = try #require(model.api)
        let store = ChannelStore(id: "channel", api: api)
        let session = model.artifactSession(for: store)
        session.open(ChannelArtifact(file: .init(kind: "machine", path: "document.md"), title: "Document"))
        #expect(model.artifactSession(for: store) === session)
        #expect(session.isPresented)
        let replacement = model.artifactSession(for: ChannelStore(id: store.id, api: api))
        #expect(replacement !== session)
        #expect(!session.isPresented)
        #expect(replacement.channelID == store.id)
        #expect(replacement.server == api.baseURL)
    }

    @Test func changingSelectionClosesTheVisitAndChangingServerDiscardsItsSession() throws {
        let suite = "mobile-overview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:], defaults: defaults)
        let artifact = ChannelArtifact(file: .init(kind: "machine", path: "document.md"), title: "Document")
        model.selectedChannelID = "first"
        let first = model.artifactSession(for: try #require(model.selectedStore))
        first.open(artifact)
        model.selectedChannelID = "second"
        #expect(!first.isPresented)
        let second = model.artifactSession(for: try #require(model.selectedStore))
        second.open(artifact)
        try model.configure(serverURL: "https://replacement.example", persist: false)
        #expect(!second.isPresented)
        #expect(model.selectedStore == nil)
        model.selectedChannelID = "second"
        let replacement = model.artifactSession(for: try #require(model.selectedStore))
        #expect(replacement !== second)
        #expect(replacement.server?.host == "replacement.example")
    }
}
