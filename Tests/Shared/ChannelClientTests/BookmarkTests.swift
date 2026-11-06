import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct BookmarkTests {
    @Test func aServerWithoutBookmarksHidesThemAndIsNeverAsked() async throws {
        let mock = MockTransport { _, _ in MockResponse(status: 204) }
        let store = try connectedStore(mock, bookmarks: nil)
        #expect(store.bookmarks == nil)
        await store.setBookmarked(true, sequence: 2)
        #expect(store.bookmarks == nil)
        #expect(store.bookmarkError == nil)
        #expect(mock.requests.isEmpty)
    }

    /// The change shows while it's written, and stays until the stream echoes it, in either order.
    @Test func aBookmarkShowsAtOnceAndTheEchoConfirmsIt() async throws {
        let mock = MockTransport { _, _ in MockResponse(status: 204, keepOpen: true) }
        let store = try connectedStore(mock, bookmarks: [])

        let first = Task { await store.setBookmarked(true, sequence: 2) }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        #expect(store.bookmarks == [2])
        #expect(mock.finishPendingResponses() == 1)
        await first.value
        #expect(store.state?.bookmarks == [])
        #expect(store.bookmarks == [2])
        _ = try store.apply(.init(type: "bookmarks", revision: 11, bookmarks: [2]))
        #expect(store.bookmarks == [2])

        let second = Task { await store.setBookmarked(true, sequence: 3) }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        _ = try store.apply(.init(type: "bookmarks", revision: 12, bookmarks: [2, 3]))
        #expect(mock.finishPendingResponses() == 1)
        await second.value
        #expect(store.bookmarks == [2, 3])

        // Another device clears them, and nothing local holds either one.
        _ = try store.apply(.init(type: "bookmarks", revision: 13, bookmarks: []))
        #expect(store.bookmarks == [])
        #expect(store.bookmarkError == nil)
        #expect(mock.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "PUT /api/v1/channels/test/bookmarks/2", "PUT /api/v1/channels/test/bookmarks/3",
        ])
    }

    @Test func aRejectedChangeIsUndoneAndSaysWhy() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(status: 422, body: Data(#"{"error":"Bookmark a user or agent message in this Channel."}"#.utf8))
        }
        let store = try connectedStore(mock, bookmarks: [2])
        await store.setBookmarked(false, sequence: 2)
        #expect(store.bookmarks == [2])
        #expect(store.bookmarkError == "Bookmark a user or agent message in this Channel. (HTTP 422)")
        #expect(mock.requests.count == 1)
        store.dismissBookmarkError()
        #expect(store.bookmarkError == nil)
    }

    /// A quick second toggle waits for the first write, so the server can't apply them out of order.
    @Test func togglesWriteInOrderAndEndWhereTheUserLeftThem() async throws {
        let log = Mutex<[String]>([])
        let mock = MockTransport { request, count in
            log.withLock { $0.append(request.httpMethod ?? "") }
            return MockResponse(status: 204, keepOpen: count == 1)
        }
        let store = try connectedStore(mock, bookmarks: [])
        let on = Task { await store.setBookmarked(true, sequence: 2) }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        let off = Task { await store.setBookmarked(false, sequence: 2) }
        try await eventually { store.bookmarks == [] }
        log.withLock { $0.append("finished PUT") }
        #expect(mock.finishPendingResponses() == 1)
        await on.value
        await off.value
        #expect(log.withLock { $0 } == ["PUT", "finished PUT", "DELETE"])
        #expect(store.bookmarks == [])
        #expect(store.bookmarkError == nil)
    }

    /// A store connected to a channel with messages 1 to 3, as if its stream had just opened.
    private func connectedStore(_ mock: MockTransport, bookmarks: [Int]?) throws -> ChannelStore {
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        var state = testState(revision: 10, messages: [testMessage(1), testMessage(2), testMessage(3)])
        state.bookmarks = bookmarks
        _ = try store.apply(.init(type: "snapshot", state: state))
        return store
    }
}
