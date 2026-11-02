import ChannelKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ChannelClient

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChannelComposerSessionTests {
    @Test func replyInsertsTheHandleOnceAndKeepsTheDraft() throws {
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        draft.text = "Keep these words"
        let store = ChannelStore(id: "test", api: try ChannelAPI(serverURL: "http://localhost:3210"),
                                 sendJournal: nil)
        let session = ChannelComposerSession(store: store, draft: draft)
        let agent = ChannelAgent(id: "ada", name: "Ada Lovelace")
        #expect(session.reply(to: agent))
        #expect(draft.text == "@ada-lovelace Keep these words")
        #expect(session.reply(to: agent))
        #expect(draft.text == "@ada-lovelace Keep these words")
    }

    @Test func aSentReplyKeepsNewerWordsAndAnOldEchoCannotClearThem() throws {
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        draft.text = "@ada-lovelace Keep these words"
        let store = ChannelStore(id: "test", api: try ChannelAPI(serverURL: "http://localhost:3210"),
                                 sendJournal: nil)
        let session = ChannelComposerSession(store: store, draft: draft)
        draft.associateSend(id: "original")
        draft.text = "A newer draft"
        _ = try store.apply(.init(type: "snapshot", state: testState(
            revision: 1, messages: [testMessage(9, id: "original")]
        )))
        session.reconcile()
        #expect(draft.text == "A newer draft")
        store.disconnect()
        #expect(!session.canSend(hasAdditionalContent: true))
    }

    @Test func anOfflineSessionNeverReadsItsBlockers() throws {
        let store = ChannelStore(id: "test", api: try ChannelAPI(serverURL: "http://localhost:3210"),
                                 sendJournal: nil)
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
    func aRejectedSendLivesOnItsRowAndRetryReusesTheAttemptUUID(status: Int) async throws {
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
        try await eventually { store.phase.isConnected }
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        draft.text = "Send once"
        let session = ChannelComposerSession(store: store, draft: draft)
        #expect(await !session.send())
        let attempt = try #require(store.sendAttempts.first)
        #expect(attempt.content == "Send once")
        #expect(attempt.phase == (status == 422 ? .notSent : .deliveryNotConfirmed))
        #expect(attempt.canRetry)
        #expect(draft.text.isEmpty)
        #expect(draft.sendAttemptID == nil)
        #expect(session.error == nil)
        _ = try await store.retrySend(id: attempt.id)
        #expect(store.messages.contains { $0.id == attempt.id })
        #expect(try mock.requests.filter { $0.httpMethod == "POST" }.map {
            try SendAttemptTests.posted($0).id
        } == [attempt.id, attempt.id])
    }

    @Test func aKeptSubmitReturnsTheCommittedMessageAndClearsOnlyWhenTheCallerConfirms() async throws {
        let mock = MockTransport { request, _ in
            guard request.httpMethod == "POST" else {
                return try .stream([.init(type: "snapshot", state: testState())])
            }
            let posted = try SendAttemptTests.posted(request)
            let message = ChannelMessage(id: posted.id, sequence: 1, timestamp: "2026-10-01T00:00:00Z",
                                         sender: .user, content: .text(posted.content))
            return try .json(SendAttemptTests.MessageEnvelope(message: message), status: 201)
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        draft.text = "Kept words"
        let session = ChannelComposerSession(store: store, draft: draft, keepsDraftUntilConfirmed: true)
        let result = try #require(await session.submit())
        guard case .committed(let message) = result else {
            Issue.record("Expected a committed result, got \(result)")
            return
        }
        #expect(message.id == draft.sendAttemptID)
        #expect(draft.text == "Kept words")
        session.reconcile()
        #expect(draft.text.isEmpty)
        #expect(draft.sendAttemptID == nil)
    }

    @Test func aKeptSubmitThatIsRejectedLeavesItsDraftAndAttemptForRetry() async throws {
        let mock = MockTransport { request, _ in
            guard request.httpMethod == "POST" else {
                return try .stream([.init(type: "snapshot", state: testState())])
            }
            return MockResponse(status: 422, body: Data(#"{"error":"Rejected"}"#.utf8))
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        draft.text = "Rejected words"
        let session = ChannelComposerSession(store: store, draft: draft, keepsDraftUntilConfirmed: true)
        #expect(await session.submit() == nil)
        let attempt = try #require(store.sendAttempts.first)
        #expect(attempt.phase == .notSent)
        #expect(attempt.canRetry)
        #expect(draft.text == "Rejected words")
        #expect(draft.sendAttemptID == attempt.id)
        #expect(session.error == nil)
    }

    @Test func theDraftClearsOnceTheOutboxSavesWhileTheRequestIsStillInFlight() async throws {
        let mock = Self.heldPost()
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        draft.text = "Instant words"
        let session = ChannelComposerSession(store: store, draft: draft)
        let send = Task { await session.send() }
        try await eventually(observing: mock) { mock.pendingResponseCount == 2 }
        #expect(draft.text.isEmpty)
        #expect(draft.sendAttemptID == nil)
        let attempt = try #require(store.sendAttempts.first)
        #expect(attempt.content == "Instant words")
        #expect(attempt.phase == .sending)
        #expect(session.isSubmitting)
        mock.finishPendingResponses()
        #expect(await send.value)
        #expect(draft.text.isEmpty)
        #expect(store.messages.contains { $0.id == attempt.id })
    }

    @Test func aRefusedSendKeepsItsDraftWhileAnotherSendIsInFlight() async throws {
        let mock = Self.heldPost()
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        let first = ComposerDraft(imageIsReadable: { _ in false })
        first.text = "First words"
        let firstSession = ChannelComposerSession(store: store, draft: first)
        let send = Task { await firstSession.send() }
        try await eventually(observing: mock) { mock.pendingResponseCount == 2 }
        let second = ComposerDraft(imageIsReadable: { _ in false })
        second.text = "Second words"
        let secondSession = ChannelComposerSession(store: store, draft: second)
        #expect(!secondSession.canSend())
        #expect(await !secondSession.send())
        #expect(second.text == "Second words")
        #expect(second.sendAttemptID == nil)
        #expect(store.sendAttempts.map(\.content) == ["First words"])
        mock.finishPendingResponses()
        #expect(await send.value)
        #expect(second.text == "Second words")
    }

    @Test func aLaterFailureLeavesTheNewerDraftAloneAndTheAttemptRetryable() async throws {
        let mock = Self.heldPost(status: 503)
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        draft.text = "Held words"
        let session = ChannelComposerSession(store: store, draft: draft)
        let send = Task { await session.send() }
        try await eventually(observing: mock) { mock.pendingResponseCount == 2 }
        #expect(draft.text.isEmpty)
        draft.text = "A newer draft"
        mock.finishPendingResponses()
        #expect(await !send.value)
        #expect(draft.text == "A newer draft")
        #expect(draft.sendAttemptID == nil)
        #expect(session.error == nil)
        let attempt = try #require(store.sendAttempts.first)
        #expect(attempt.content == "Held words")
        #expect(attempt.phase == .deliveryNotConfirmed)
        #expect(attempt.canRetry)
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
        try await eventually { store.phase.isConnected }
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
        try await eventually { store.phase.isConnected }
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

    private static func heldPost(status: Int? = nil) -> MockTransport {
        MockTransport { request, _ in
            guard request.httpMethod == "POST" else {
                return try .stream([.init(type: "snapshot", state: testState())])
            }
            if let status {
                var response = MockResponse(status: status, body: Data(#"{"error":"Response lost"}"#.utf8))
                response.keepOpen = true
                return response
            }
            let posted = try SendAttemptTests.posted(request)
            let message = ChannelMessage(id: posted.id, sequence: 1, timestamp: "2026-10-01T00:00:00Z",
                                         sender: .user, content: .text(posted.content))
            var response = try MockResponse.json(SendAttemptTests.MessageEnvelope(message: message), status: 201)
            response.keepOpen = true
            return response
        }
    }

    private struct ImagePost: Decodable {
        let id: String
        let content: String
        let attachments: [ChannelAttachment]
    }
}
