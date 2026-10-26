import ChannelKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ChannelClient

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChannelComposerSessionTests {
    @Test func replyContextUsesTheSourceAndAnOldEchoCannotClearNewerWords() throws {
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        draft.text = "Keep these words"
        let store = ChannelStore(id: "test", api: try ChannelAPI(serverURL: "http://localhost:3210"),
                                 sendJournal: nil)
        let session = ChannelComposerSession(store: store, draft: draft)
        let agent = ChannelAgent(id: "ada", name: "Ada Lovelace")
        session.reply(to: agent, sequence: 8)
        #expect(draft.text == "@ada-lovelace Keep these words")
        #expect(session.replySource?.sequence == 8)
        session.reply(to: agent)
        #expect(draft.text == "@ada-lovelace Keep these words")
        draft.associateSend(id: "original")
        draft.text = "A newer draft"
        _ = try store.apply(.init(type: "snapshot", state: testState(
            revision: 1, messages: [testMessage(9, id: "original")]
        )))
        session.reconcile()
        #expect(draft.text == "A newer draft")
        #expect(session.replySource?.sequence == 8)
        store.disconnect()
        #expect(!session.canSend(hasAdditionalContent: true))
    }

    @Test func recoveryPreservesBothMessagesAndRequiresANewIdentityAfterAppending() throws {
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        let store = ChannelStore(id: "test", api: try ChannelAPI(serverURL: "http://localhost:3210"),
                                 sendJournal: nil)
        let session = ChannelComposerSession(store: store, draft: draft)
        let attempt = ChannelSendAttempt(id: "original", content: "Unsent words", attachments: [],
                                         timestamp: "2026-10-01T00:00:00Z", phase: .notSent)
        #expect(session.edit(attempt))
        #expect(draft.text == attempt.content)
        #expect(draft.sendAttemptID == attempt.id)
        draft.text = "Newer words"
        #expect(!session.edit(attempt))
        #expect(draft.text == "Newer words")
        #expect(session.pendingEdit?.id == attempt.id)
        #expect(session.appendPendingEdit())
        #expect(draft.text == "Newer words\n\nUnsent words")
        #expect(draft.sendAttemptID == nil)
        #expect(session.pendingEdit == nil)
    }

    @Test(arguments: [422, 503])
    func anExplicitRetryReusesTheUUIDAndOnlyConfirmationClearsTheDraft(status: Int) async throws {
        let mock = MockTransport { request, count in
            guard request.httpMethod == "POST" else {
                return try .stream([.init(type: "snapshot", state: testState())])
            }
            if count == 2 { return MockResponse(status: status, body: Data(#"{"error":"Rejected"}"#.utf8)) }
            let posted = try SendAttemptTests.posted(request)
            let message = ChannelMessage(id: posted.id, sequence: 1, timestamp: "2026-10-01T00:00:00Z",
                                         sender: .user, content: .text(posted.content))
            return try .json(SendAttemptTests.MessageEnvelope(message: message), status: 201)
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isLive }
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        draft.text = "Send once"
        let session = ChannelComposerSession(store: store, draft: draft)
        #expect(await !session.send())
        let id = try #require(draft.sendAttemptID)
        #expect(draft.text == "Send once")
        #expect(session.attempt?.phase == (status == 422 ? .notSent : .deliveryNotConfirmed))
        #expect(await session.send())
        #expect(draft.text.isEmpty)
        #expect(draft.sendAttemptID == nil)
        #expect(try mock.requests.filter { $0.httpMethod == "POST" }.map {
            try SendAttemptTests.posted($0).id
        } == [id, id])
    }

    @Test func aSuspendedSendCannotSubmitTwiceOrClearANewerDraft() async throws {
        let mock = MockTransport { request, _ in
            guard request.httpMethod == "POST" else {
                return try .stream([.init(type: "snapshot", state: testState())])
            }
            let posted = try SendAttemptTests.posted(request)
            let message = ChannelMessage(id: posted.id, sequence: 1, timestamp: "2026-10-01T00:00:00Z",
                                         sender: .user, content: .text(posted.content))
            var response = try MockResponse.json(SendAttemptTests.MessageEnvelope(message: message), status: 201)
            response.keepOpen = true
            return response
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isLive }
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        draft.text = "Original words"
        let session = ChannelComposerSession(store: store, draft: draft)
        let send = Task { await session.send() }
        try await eventually(observing: mock) { mock.pendingResponseCount == 2 }
        #expect(session.isSubmitting)
        #expect(!session.canSend())
        #expect(await !session.send())
        draft.text = "A newer draft"
        mock.finishPendingResponses()
        #expect(await send.value)
        #expect(draft.text == "A newer draft")
        #expect(!session.isSubmitting)
        #expect(mock.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test(arguments: [false, true])
    func recoveredLegacyImagesOnlyChangeForANewAttempt(edited: Bool) async throws {
        let image = try await Task.detached {
            try ComposerDraftTests.generatedImage(width: 64, height: 32, type: .heic)
        }.value
        let mock = MockTransport { request, count in
            guard request.httpMethod == "POST" else {
                return try .stream([.init(type: "snapshot", state: testState())])
            }
            if count == 2 { return MockResponse(status: 503, body: Data(#"{"error":"Response lost"}"#.utf8)) }
            let posted = try SendAttemptTests.posted(request)
            let message = ChannelMessage(id: posted.id, sequence: 1, timestamp: "2026-10-01T00:00:00Z",
                                         sender: .user, content: .text(posted.content))
            return try .json(SendAttemptTests.MessageEnvelope(message: message), status: 201)
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isLive }
        await #expect(throws: ChannelAPIError.http(status: 503, message: "Response lost")) {
            try await store.post(id: "legacy", content: "Original", attachments: [image.attachment])
        }
        let draft = ComposerDraft(imageIsReadable: { data in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
            return CGImageSourceGetCount(source) > 0
        })
        let session = ChannelComposerSession(store: store, draft: draft)
        #expect(session.edit(try #require(store.sendAttempts.first)))
        #expect(!draft.isLoadingImages)
        #expect(draft.images.first?.data == image.data)
        if edited {
            draft.text = "Edited"
            #expect(draft.isLoadingImages)
            #expect(!session.canSend())
            try await eventually { !draft.isLoadingImages }
        }
        #expect(await session.send())
        let posts = mock.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 2)
        let last = try #require(posts.last)
        let posted = try JSONDecoder().decode(ImagePost.self, from: requestBody(last))
        let attachment = try #require(posted.attachments.first)
        let bytes = try #require(attachment.base64.flatMap { Data(base64Encoded: $0) })
        if edited {
            #expect(posted.id != "legacy")
            #expect(posted.content == "Edited")
            #expect(attachment.mimeType == "image/jpeg")
            #expect(bytes != image.data)
            let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        } else {
            #expect(posted.id == "legacy")
            #expect(posted.content == "Original")
            #expect(attachment == image.attachment)
            #expect(bytes == image.data)
        }
    }

    private struct ImagePost: Decodable {
        let id: String
        let content: String
        let attachments: [ChannelAttachment]
    }
}
