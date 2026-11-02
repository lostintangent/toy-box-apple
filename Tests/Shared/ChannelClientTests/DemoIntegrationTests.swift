import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

struct DemoIntegrationTests {
    static var demoURL: String? { ProcessInfo.processInfo.environment["TOY_BOX_DEMO_URL"] }

    @Test(.enabled(if: demoURL != nil))
    func modelCatalogEnablesTheConfiguredChoice() async throws {
        let api = try ChannelAPI(serverURL: #require(Self.demoURL))
        let models = try await api.models()
        let catalog = try await api.catalog()
        let channel = try #require(catalog.channels.first)
        let selection = ChannelModelSelection(model: channel.model, catalog: models, scope: .channel)
        #expect(selection.isEnabled)
        #expect(selection.selected?.id == channel.model.name)
        #expect(selection.selected?.provider == channel.model.provider)
    }

    @Test(.enabled(if: demoURL != nil))
    func catalogSnapshotPostConflictReadAndResume() async throws {
        let api = try ChannelAPI(serverURL: #require(Self.demoURL))
        guard api.baseURL.port == 3210, ["localhost", "127.0.0.1"].contains(api.baseURL.host) else {
            throw ChannelAPIError.invalidServerURL
        }
        let catalog = try await api.catalog()
        let channel = try #require(catalog.channels.first)
        #expect(channel.id == "studio-demo")
        let stream = api.observe(channelId: channel.id)
        var iterator = stream.makeAsyncIterator()
        let event = try #require(try await iterator.next())
        let snapshot = try #require(event.state)
        #expect(event.type == "snapshot")
        #expect(snapshot.members.count == 8)
        let id = UUID().uuidString
        let posted = try await api.post(channelId: channel.id, id: id, content: "Mac client fixture integration")
        #expect(posted.id == id)
        #expect(posted.sender == .user)
        let echo = try #require(try await iterator.next())
        #expect(echo.message?.id == id)
        let revision = try #require(echo.revision)
        await #expect(throws: ChannelAPIError.duplicateMessage) {
            try await api.post(channelId: channel.id, id: id, content: "Not duplicated")
        }
        let seen = try await api.markRead(channelId: channel.id, sequence: posted.sequence)
        #expect(seen == posted.sequence)
        let resumedStream = api.observe(channelId: channel.id, after: revision)
        var resumed = resumedStream.makeAsyncIterator()
        let read = try #require(try await resumed.next())
        #expect(read.type == "read")
        #expect(read.seenThrough == seen)
        let resume = try #require(try await resumed.next())
        #expect(resume.type == "resumed")
        #expect(resume.presence?.count == 9)
    }
}
