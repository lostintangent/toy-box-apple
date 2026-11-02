import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

@Suite(.timeLimit(.minutes(1)))
struct SendAttemptTests {
    struct Posted: Decodable { var id: String; var content: String }
    struct MessageEnvelope: Encodable { var version = 1; var message: ChannelMessage }

    static func posted(_ request: URLRequest) throws -> Posted {
        try JSONDecoder().decode(Posted.self, from: requestBody(request))
    }

    @Test @MainActor func backgroundPostPersistsBeforeItsOnlyRequestWithoutOpeningAStream() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-background-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ChannelSendJournal(directory: directory)
        let id = UUID().uuidString
        let mock = MockTransport { request, _ in
            #expect(request.httpMethod == "POST")
            let body = try Self.posted(request)
            let file = try #require(FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ).first)
            let attempts = try JSONDecoder().decode([ChannelSendAttempt].self, from: Data(contentsOf: file))
            #expect(attempts.map(\.id) == [id])
            #expect(attempts.first?.content == "@lead Yes, ship it.")
            #expect(attempts.first?.phase == .sending)
            let message = ChannelMessage(id: body.id, sequence: 17, timestamp: "2026-10-01T00:00:00Z",
                                         sender: .user, content: .text(body.content))
            return try .json(MessageEnvelope(message: message), status: 201)
        }
        let api = try mock.api()
        let store = ChannelStore(id: "test", api: api, sendJournal: journal)
        let result = try await store.postInBackground(id: id, content: "  @lead Yes, ship it.  ")
        guard case .committed(let message) = result else { Issue.record("Expected a committed reply"); return }
        #expect(message.id == id)
        #expect(message.sequence == 17)
        #expect(store.state == nil)
        #expect(store.phase == .connecting)
        #expect(store.sendAttempts.isEmpty)
        #expect(try await journal.load(server: api.baseURL, channelId: "test").isEmpty)
        #expect(mock.requests.count == 1)
    }

    @Test(arguments: [422, 503])
    @MainActor func backgroundFailureKeepsItsClassificationAndUUIDForAnExplicitRetry(status: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-background-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ChannelSendJournal(directory: directory)
        let id = UUID().uuidString
        let mock = MockTransport { request, count in
            #expect(request.httpMethod == "POST")
            let body = try Self.posted(request)
            #expect(body.id == id)
            return count == 1
                ? MockResponse(status: status, body: Data(#"{"error":"Reply failed"}"#.utf8))
                : MockResponse(status: 409, body: Data(#"{"error":"Message ID already exists."}"#.utf8))
        }
        let api = try mock.api()
        let store = ChannelStore(id: "test", api: api, sendJournal: journal)
        await #expect(throws: ChannelAPIError.http(status: status, message: "Reply failed")) {
            try await store.postInBackground(id: id, content: "Keep my reply")
        }
        let phase: ChannelSendPhase = status == 422 ? .notSent : .deliveryNotConfirmed
        #expect(store.sendAttempts.first?.phase == phase)
        #expect(store.lastSendFailure?.phase == phase)
        #expect(try await journal.load(server: api.baseURL, channelId: "test") == store.sendAttempts)
        #expect(mock.requests.count == 1)

        let restored = ChannelStore(id: "test", api: api, sendJournal: journal)
        let retry = try await restored.postInBackground(id: id, content: "Keep my reply")
        #expect(retry == .alreadyAccepted(id: id))
        #expect(restored.sendAttempts.first?.phase == .confirmed)
        #expect(restored.phase == .connecting)
        #expect(try await journal.load(server: api.baseURL, channelId: "test") == restored.sendAttempts)
        #expect(try await restored.postInBackground(id: id, content: "Keep my reply") == retry)
        await #expect(throws: ChannelAPIError.invalidMessage(
            "The attempted message changed. Send it as a new message."
        )) {
            try await restored.postInBackground(id: id, content: "Different reply")
        }
        #expect(mock.requests.count == 2)
    }

    @Test @MainActor func theCatalogHearsOnlySendsTheServerAcceptsWithTheirAttachments() async throws {
        struct PostedImages: Decodable { var id: String; var attachments: [ChannelAttachment]? }
        let image = ChannelAttachment(name: "Screenshot.png", mimeType: "image/png", base64: "iVBORw0K")
        let id = UUID().uuidString
        let mock = MockTransport { request, count in
            let body = try JSONDecoder().decode(PostedImages.self, from: requestBody(request))
            #expect(body.id == id)
            #expect(body.attachments == [image])
            guard count == 2 else { return MockResponse(status: 503, body: Data(#"{"error":"Busy"}"#.utf8)) }
            let message = ChannelMessage(id: id, sequence: 18, timestamp: "2026-10-31T05:00:00Z",
                                         sender: .user, content: .text("Look"), attachments: [image])
            return try .json(MessageEnvelope(message: message), status: 201)
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        var confirmed: [String] = []
        catalog.onSendConfirmed = { confirmed.append($0) }
        let store = catalog.channel(id: "studio")

        await #expect(throws: ChannelAPIError.http(status: 503, message: "Busy")) {
            try await store.postInBackground(id: id, content: "Look", attachments: [image])
        }
        #expect(confirmed.isEmpty)
        let result = try await store.postInBackground(id: id, content: "Look", attachments: [image])
        guard case .committed(let message) = result else { Issue.record("Expected a committed send"); return }
        #expect(message.attachments == [image])
        #expect(confirmed == ["studio"])
        #expect(mock.requests.count == 2)
    }

    @Test @MainActor func backgroundTransportFailureIsNotAutomaticallyRetried() async throws {
        let mock = MockTransport { _, _ in throw URLError(.networkConnectionLost) }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        let id = UUID().uuidString
        await #expect(throws: URLError.self) {
            try await store.postInBackground(id: id, content: "One attempt")
        }
        #expect(store.sendAttempts.first?.id == id)
        #expect(store.sendAttempts.first?.phase == .deliveryNotConfirmed)
        #expect(mock.requests.count == 1)
        #expect(store.phase == .connecting)
    }

    @Test @MainActor func backgroundReplyDuringAnotherSendIsDurablyRetainedWithoutPosting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-background-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ChannelSendJournal(directory: directory)
        let mock = MockTransport { request, _ in
            let body = try Self.posted(request)
            var response = try MockResponse.json(MessageEnvelope(message: ChannelMessage(
                id: body.id, sequence: 17, timestamp: "2026-10-01T00:00:00Z",
                sender: .user, content: .text(body.content)
            )), status: 201)
            response.keepOpen = true
            return response
        }
        defer { _ = mock.finishPendingResponses() }
        let api = try mock.api()
        let store = ChannelStore(id: "test", api: api, sendJournal: journal)
        let firstID = UUID().uuidString
        let first = Task { try await store.postInBackground(id: firstID, content: "First") }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        let replyID = UUID().uuidString
        await #expect(throws: ChannelAPIError.invalidMessage("A message is already being sent.")) {
            try await store.postInBackground(id: replyID, content: "@lead Keep this reply")
        }
        let reply = try #require(store.sendAttempts.first { $0.id == replyID })
        #expect(reply.phase == .notSent)
        #expect(reply.content == "@lead Keep this reply")
        #expect(store.sendAttempts.first { $0.id == firstID }?.phase == .sending)
        #expect(try await journal.load(server: api.baseURL, channelId: "test").first { $0.id == replyID } == reply)
        #expect(mock.requests.count == 1)
        #expect(mock.finishPendingResponses() == 1)
        _ = try await first.value
        #expect(store.sendAttempts == [reply])
        #expect(try await journal.load(server: api.baseURL, channelId: "test") == [reply])
    }

    @Test @MainActor func backgroundPostNeverSendsWhenTheJournalCannotBeWritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-background-\(UUID())")
        let journal = ChannelSendJournal(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = MockTransport { _, _ in
            Issue.record("A failed outbox write must prevent the HTTP request")
            throw URLError(.unknown)
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: journal)
        await #expect(throws: ChannelAPIError.invalidMessage("A message or attachment is required.")) {
            try await store.postInBackground(id: UUID().uuidString, content: " ")
        }
        try Data("Not a directory".utf8).write(to: directory)
        let id = UUID().uuidString
        await #expect(throws: (any Error).self) {
            try await store.postInBackground(id: id, content: "Do not send")
        }
        #expect(store.sendAttempts.first?.id == id)
        #expect(store.sendAttempts.first?.phase == .notSent)
        #expect(store.attemptPersistenceError != nil)
        #expect(mock.requests.isEmpty)
    }

    @Test @MainActor func explicitRetryUsesOriginalUUIDAndReplacesAttemptOnCommit() async throws {
        let initial = testState()
        let mock = MockTransport { request, count in
            if request.httpMethod == "POST" {
                if count == 2 { return MockResponse(status: 422, body: Data(#"{"error":"Rejected"}"#.utf8)) }
                let body = try Self.posted(request)
                let message = ChannelMessage(id: body.id, sequence: 1, timestamp: "2026-10-01T00:00:00Z",
                                             sender: .user, content: .text(body.content))
                return try .json(MessageEnvelope(message: message), status: 201)
            }
            return try .stream([.init(type: "snapshot", state: initial)])
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        await #expect(throws: ChannelAPIError.http(status: 422, message: "Rejected")) {
            try await store.post(content: "Original")
        }
        let attempt = try #require(store.sendAttempts.first)
        #expect(attempt.phase == .notSent)
        #expect(store.lastSendFailure?.messageId == attempt.id)
        #expect(store.lastSendFailure?.phase == .notSent)
        #expect(attempt.content == "Original")
        #expect(store.state?.messages.isEmpty == true)
        let result = try await store.post(id: attempt.id, content: "Original")
        guard case .committed(let message) = result else { Issue.record("Expected a committed result"); return }
        #expect(message.id == attempt.id)
        #expect(store.sendAttempts.isEmpty)
        #expect(store.lastSendFailure == nil)
        #expect(store.state?.messages.map(\.id) == [attempt.id])
        let posts = mock.requests.filter { $0.httpMethod == "POST" }
        #expect(try posts.map { try Self.posted($0).id } == [attempt.id, attempt.id])
        let repeated = try await store.post(id: attempt.id, content: "Original")
        #expect(repeated == .committed(message))
        await #expect(throws: ChannelAPIError.invalidMessage(
            "The message ID already belongs to different content. Send it as a new message."
        )) {
            try await store.post(id: attempt.id, content: "Edited after delivery")
        }
        await #expect(throws: ChannelAPIError.invalidMessage(
            "The message ID already belongs to different content. Send it as a new message."
        )) {
            try await store.post(id: attempt.id, content: "Original",
                                 attachments: [.init(mimeType: "image/png", base64: "AAAA")])
        }
        #expect(mock.requests.filter { $0.httpMethod == "POST" }.count == 2)
    }

    @Test @MainActor func lostResponseThenConflictConfirmsOriginalAcceptance() async throws {
        let initial = testState()
        let mock = MockTransport { request, count in
            if request.httpMethod == "POST" {
                if count == 2 { throw URLError(.networkConnectionLost) }
                return MockResponse(status: 409, body: Data(#"{"error":"Message ID already exists."}"#.utf8))
            }
            return try .stream([.init(type: "snapshot", state: initial)])
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        await #expect(throws: URLError.self) { try await store.post(content: "Do not duplicate") }
        let attempt = try #require(store.sendAttempts.first)
        #expect(attempt.phase == .deliveryNotConfirmed)
        let result = try await store.retrySend(id: attempt.id)
        #expect(result == .alreadyAccepted(id: attempt.id))
        try await eventually { store.phase.isConnected && store.sendAttempts.isEmpty }
        let posts = mock.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 2)
        #expect(try posts.map { try Self.posted($0).id } == [attempt.id, attempt.id])
    }

    @Test(arguments: [422, 503])
    @MainActor func repeatedRetryFailuresHaveNewEventsAndTheSameDeliveryUUID(status: Int) async throws {
        let initial = testState()
        let mock = MockTransport { request, _ in
            if request.httpMethod == "POST" {
                return MockResponse(status: status, body: Data(#"{"error":"Repeated failure"}"#.utf8))
            }
            return try .stream([.init(type: "snapshot", state: initial)])
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        #expect(store.lastSendFailure == nil)
        let id = UUID().uuidString
        let expectedError = ChannelAPIError.http(status: status, message: "Repeated failure")
        await #expect(throws: expectedError) { try await store.post(id: id, content: "Keep this UUID") }
        let first = try #require(store.lastSendFailure)
        #expect(first.messageId == id)
        #expect(first.phase == (status == 422 ? .notSent : .deliveryNotConfirmed))
        #expect(first.error == expectedError.localizedDescription)
        #expect(store.lastSendFailure == first)
        await #expect(throws: expectedError) { try await store.retrySend(id: id) }
        let retry = try #require(store.lastSendFailure)
        #expect(retry.id != first.id)
        #expect(retry.messageId == first.messageId)
        #expect(retry.phase == first.phase)
        #expect(retry.error == first.error)
        #expect(store.sendAttempts.count == 1)
        #expect(store.sendAttempts.first?.id == id)
        let posts = mock.requests.filter { $0.httpMethod == "POST" }
        #expect(try posts.map { try Self.posted($0).id } == [id, id])
        store.reconnect()
        try await eventually { store.phase.isConnected }
        #expect(store.lastSendFailure == retry)
        try await store.discardSendAttempt(id: id)
        #expect(store.lastSendFailure == nil)
        #expect(store.sendAttempts.isEmpty)
    }

    @Test(arguments: [ChannelSendPhase.sending, .notSent, .deliveryNotConfirmed])
    @MainActor func restoredAttemptsDoNotEmitFailureEvents(phase: ChannelSendPhase) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-outbox-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ChannelSendJournal(directory: directory)
        let initial = testState()
        let mock = MockTransport { _, _ in try .stream([.init(type: "snapshot", state: initial)]) }
        let api = try mock.api()
        let attempt = ChannelSendAttempt(id: UUID().uuidString, content: "Preserved",
                                         attachments: [.init(mimeType: "image/png", base64: "AAAA")],
                                         timestamp: "2026-10-01T00:00:00Z", phase: phase)
        try await journal.save([attempt], server: api.baseURL, channelId: "test")
        let store = ChannelStore(id: "test", api: api, sendJournal: journal)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        #expect(store.sendAttempts.first?.id == attempt.id)
        #expect(store.sendAttempts.first?.phase == (phase == .sending ? .deliveryNotConfirmed : phase))
        #expect(store.sendAttempts.first?.attachments == attempt.attachments)
        #expect(store.lastSendFailure == nil)
        #expect(mock.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(try await journal.load(server: api.baseURL, channelId: "other").isEmpty)
    }

    @Test(arguments: [false, true])
    @MainActor func restoredAttemptsReconcileWithTheFirstSnapshot(snapshotArrivesFirst: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-outbox-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer {
            started.continuation.finish()
            release.continuation.finish()
        }
        let journal = if snapshotArrivesFirst {
            ChannelSendJournal(directory: directory, beforeLoad: {
                started.continuation.yield()
                var releases = release.stream.makeAsyncIterator()
                _ = await releases.next()
            })
        } else {
            ChannelSendJournal(directory: directory)
        }
        let id = UUID().uuidString
        let content = "Accepted before the app quit"
        let message = ChannelMessage(id: id, sequence: 1, timestamp: "2026-10-01T00:00:00Z",
                                     sender: .user, content: .text(content))
        let mock = MockTransport { _, _ in
            try .stream([.init(type: "snapshot", state: testState(revision: 1, messages: [message]))])
        }
        let api = try mock.api()
        try await journal.save([.init(id: id, content: content, attachments: [],
                                      timestamp: "2026-10-01T00:00:00Z", phase: .sending)],
                               server: api.baseURL, channelId: "test")
        let store = ChannelStore(id: "test", api: api, sendJournal: journal)
        defer { store.disconnect() }
        if !snapshotArrivesFirst {
            await #expect(throws: ChannelAPIError.disconnected) { try await store.retrySend(id: "unknown") }
            #expect(store.sendAttempts.map(\.id) == [id])
        }
        store.connect()
        if snapshotArrivesFirst {
            var loads = started.stream.makeAsyncIterator()
            try #require(await loads.next() != nil)
            // The stream opened alongside the restore, so its snapshot is in flight.
            try await eventually(observing: mock) { mock.requests.count == 1 }
            #expect(store.state == nil)
            #expect(store.phase == .connecting)
            release.continuation.yield()
        }
        try await eventually { store.phase.isConnected }
        await #expect(throws: ChannelAPIError.self) { try await store.retrySend(id: "unknown") }
        #expect(store.state?.messages.map(\.id) == [id])
        #expect(store.sendAttempts.isEmpty)
        #expect(store.optimisticMessageIds.isEmpty)
        #expect(mock.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test @MainActor func snapshotConfirmationClearsTheFailureWithoutRetrying() async throws {
        let id = UUID().uuidString
        let content = "Accepted before the response was lost"
        let initial = testState()
        let message = ChannelMessage(id: id, sequence: 1, timestamp: "2026-10-01T00:00:00Z",
                                     sender: .user, content: .text(content))
        let confirmed = testState(revision: 1, messages: [message])
        let mock = MockTransport { request, count in
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return try .stream([.init(type: "snapshot", state: count == 1 ? initial : confirmed)])
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        await #expect(throws: URLError.self) { try await store.post(id: id, content: content) }
        #expect(store.lastSendFailure?.messageId == id)
        store.reconnect()
        try await eventually { store.phase.isConnected && store.state?.messages.first?.id == id }
        #expect(store.lastSendFailure == nil)
        #expect(store.sendAttempts.isEmpty)
        #expect(mock.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test @MainActor func journalWriteFailuresEmitANewEventForEachExplicitDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-outbox-write-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ChannelSendJournal(directory: directory)
        let initial = testState()
        let mock = MockTransport { _, _ in try .stream([.init(type: "snapshot", state: initial)]) }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: journal)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        try FileManager.default.removeItem(at: directory)
        try Data("Not a directory".utf8).write(to: directory)
        let id = UUID().uuidString
        await #expect(throws: (any Error).self) { try await store.post(id: id, content: "Preserve this UUID") }
        let first = try #require(store.lastSendFailure)
        #expect(first.messageId == id)
        #expect(first.phase == .notSent)
        #expect(first.error == store.attemptPersistenceError)
        #expect(store.sendAttempts.first { $0.id == id }?.error == first.error)
        await #expect(throws: (any Error).self) { try await store.retrySend(id: id) }
        let retry = try #require(store.lastSendFailure)
        #expect(retry.id != first.id)
        #expect(retry.messageId == id)
        #expect(retry.phase == .notSent)
        #expect(mock.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test @MainActor func journalFailurePreventsDelivery() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-outbox-file-\(UUID())")
        try Data("Not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let journal = ChannelSendJournal(directory: file)
        let initial = testState()
        let mock = MockTransport { _, _ in try .stream([.init(type: "snapshot", state: initial)]) }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: journal)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        await #expect(throws: (any Error).self) { try await store.post(content: "Must not leave without its UUID") }
        #expect(store.attemptPersistenceError != nil)
        #expect(store.lastSendFailure == nil)
        #expect(store.sendAttempts.isEmpty)
        #expect(mock.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}
