import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChannelComposerSessionTests {
    @Test func replyInsertsTheHandleOnceAndKeepsTheDraft() throws {
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        draft.text = "Keep these words"
        let store = ChannelStore(id: "test", api: try ChannelAPI(serverURL: "http://localhost:3210"))
        let session = ChannelComposerSession(store: store, draft: draft)
        let agent = ChannelAgent(id: "ada", name: "Ada Lovelace")
        #expect(session.reply(to: agent))
        #expect(draft.text == "@ada-lovelace Keep these words")
        #expect(session.reply(to: agent))
        #expect(draft.text == "@ada-lovelace Keep these words")
    }

    @Test func anOfflineSessionNeverReadsItsBlockers() throws {
        let store = ChannelStore(id: "test", api: try ChannelAPI(serverURL: "http://localhost:3210"))
        let session = ChannelComposerSession(store: store, draft: ComposerDraft(imageIsReadable: { _ in false }))
        var blockerReads = 0
        func blocked() -> Bool {
            blockerReads += 1
            return true
        }
        let allowed = session.canSend(isBlocked: blocked())
        #expect(!allowed)
        #expect(blockerReads == 0)
    }

    @Test func aSendHandsTheDraftToTheOutboxAndFreesSendBeforeItsRequestEnds() async throws {
        let folder = ChannelOutboxTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let served = ChannelOutboxTests.Served(ChannelOutboxTests.catalog())
        let mock = ChannelOutboxTests.transport(served) { number, request in
            struct Body: Decodable { var id: String }
            let id = try JSONDecoder().decode(Body.self, from: requestBody(request)).id
            var response = try MockResponse.json(ChannelOutboxTests.userMessage(id: id, sequence: number))
            response.keepOpen = true
            return response
        }
        let outbox = ChannelOutbox(folder: folder)
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        catalog.outbox = outbox
        let store = catalog.channel(id: "test")
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        let posts = "/api/v1/channels/test/messages"

        let draft = ComposerDraft(imageIsReadable: { _ in false })
        let session = ChannelComposerSession(store: store, draft: draft)
        draft.text = " First "
        #expect(await session.send() != nil)
        #expect(draft.text.isEmpty)
        try await eventually(observing: mock) { mock.pendingCount(for: posts) == 1 }
        draft.text = "Second"
        #expect(session.canSend())
        #expect(await session.send() != nil)
        #expect(store.sending.map(\.text) == ["First", "Second"])
        #expect(served.posted.map(\.content) == ["First"])

        mock.finishPendingResponses()
        try await eventually(observing: mock) { served.posted.count == 2 && mock.pendingCount(for: posts) == 1 }
        mock.finishPendingResponses()
        try await eventually { store.sending.isEmpty }
        #expect(served.posted.map(\.content) == ["First", "Second"])
    }
}
