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
    func catalogSnapshotPostRepeatReadAndResume() async throws {
        let api = try ChannelAPI(serverURL: #require(Self.demoURL))
        // Any loopback demo, including one on its own TOY_BOX_DEMO_PORT, but never the live server.
        try #require(api.baseURL.port != 3100 && ["localhost", "127.0.0.1"].contains(api.baseURL.host))
        let catalog = try await api.catalog()
        let channel = try #require(catalog.channels.first)
        #expect(channel.id == "studio-demo")
        #expect(catalog.working.sorted() == ["ada-engineer", "iris-systems", "moss-reviewer", "pixel-designer"])
        let stream = api.subscribe(channelId: channel.id)
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
        let repeated = try await api.post(channelId: channel.id, id: id, content: "Not duplicated")
        #expect(repeated == posted)
        let seen = try await api.markRead(channelId: channel.id, sequence: posted.sequence)
        #expect(seen == posted.sequence)
        let resumedStream = api.subscribe(channelId: channel.id, after: revision)
        var resumed = resumedStream.makeAsyncIterator()
        let read = try #require(try await resumed.next())
        #expect(read.type == "read")
        #expect(read.seenThrough == seen)
        let resume = try #require(try await resumed.next())
        #expect(resume.type == "resumed")

        #expect(snapshot.bookmarks == [9, 15])
        try await api.bookmark(channelId: channel.id, sequence: 12, bookmarked: true)
        try await api.bookmark(channelId: channel.id, sequence: 12, bookmarked: true)
        try await api.bookmark(channelId: channel.id, sequence: 12, bookmarked: false)
        await #expect(throws: ChannelAPIError.http(status: 422, message: "Bookmark a user or agent message in this Channel.")) {
            try await api.bookmark(channelId: channel.id, sequence: 1, bookmarked: true)
        }
        var bookmarks: [[Int]?] = []
        while bookmarks.count < 2, let event = try await iterator.next() {
            if event.type == "bookmarks" { bookmarks.append(event.bookmarks) }
        }
        #expect(bookmarks == [[9, 12, 15], [9, 15]])
    }
}
