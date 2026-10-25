import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

struct SendAttemptTests {
    struct Posted: Decodable { var id: String; var content: String }
    struct MessageEnvelope: Encodable { var version = 1; var message: ChannelMessage }

    static func posted(_ request: URLRequest) throws -> Posted {
        try JSONDecoder().decode(Posted.self, from: requestBody(request))
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
        try await eventually { store.phase.isLive }
        await #expect(throws: ChannelAPIError.http(status: 422, message: "Rejected")) {
            try await store.post(content: "Original")
        }
        let attempt = try #require(store.sendAttempts.first)
        #expect(attempt.phase == .notSent)
        #expect(store.lastSendFailure?.messageId == attempt.id)
        #expect(store.lastSendFailure?.phase == .notSent)
        #expect(attempt.content == "Original")
        #expect(store.state?.messages.isEmpty == true)
        #expect(store.lastConfirmedSendID == nil)
        let result = try await store.post(id: attempt.id, content: "Original")
        guard case .committed(let message) = result else { Issue.record("Expected a committed result"); return }
        #expect(message.id == attempt.id)
        #expect(store.sendAttempts.isEmpty)
        #expect(store.lastSendFailure == nil)
        #expect(store.lastConfirmedSendID == attempt.id)
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
        try await eventually { store.phase.isLive }
        await #expect(throws: URLError.self) { try await store.post(content: "Do not duplicate") }
        let attempt = try #require(store.sendAttempts.first)
        #expect(attempt.phase == .deliveryNotConfirmed)
        #expect(store.lastConfirmedSendID == nil)
        let result = try await store.retrySend(id: attempt.id)
        #expect(result == .alreadyAccepted(id: attempt.id))
        #expect(store.lastConfirmedSendID == attempt.id)
        try await eventually { store.phase.isLive && store.sendAttempts.isEmpty }
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
        try await eventually { store.phase.isLive }
        #expect(store.lastSendFailure == nil)
        #expect(store.lastSendSubmission == nil)
        let id = UUID().uuidString
        let expectedError = ChannelAPIError.http(status: status, message: "Repeated failure")
        await #expect(throws: expectedError) { try await store.post(id: id, content: "Keep this UUID") }
        let firstSubmission = try #require(store.lastSendSubmission)
        let first = try #require(store.lastSendFailure)
        #expect(first.messageId == id)
        #expect(first.phase == (status == 422 ? .notSent : .deliveryNotConfirmed))
        #expect(first.error == expectedError.localizedDescription)
        #expect(store.lastSendFailure == first)
        await #expect(throws: expectedError) { try await store.retrySend(id: id) }
        #expect(try #require(store.lastSendSubmission) != firstSubmission)
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
        try await eventually { store.phase.isLive }
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
        try await eventually { store.phase.isLive }
        #expect(store.sendAttempts.first?.id == attempt.id)
        #expect(store.sendAttempts.first?.phase == (phase == .sending ? .deliveryNotConfirmed : phase))
        #expect(store.sendAttempts.first?.attachments == attempt.attachments)
        #expect(store.lastSendFailure == nil)
        #expect(mock.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(try await journal.load(server: api.baseURL, channelId: "other").isEmpty)
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
        try await eventually { store.phase.isLive }
        await #expect(throws: URLError.self) { try await store.post(id: id, content: content) }
        #expect(store.lastSendFailure?.messageId == id)
        #expect(store.lastConfirmedSendID == nil)
        store.reconnect()
        try await eventually { store.phase.isLive && store.state?.messages.first?.id == id }
        #expect(store.lastSendFailure == nil)
        #expect(store.sendAttempts.isEmpty)
        #expect(store.lastConfirmedSendID == id)
        #expect(mock.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test @MainActor func unrelatedUserMessagesDoNotConfirmALocalPost() throws {
        let mock = MockTransport { _, _ in MockResponse() }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        _ = try store.apply(.init(type: "snapshot", state: testState()))
        var message = testMessage(1)
        message.sender = .user
        _ = try store.apply(.init(type: "message", revision: 1, message: message))
        #expect(store.messages == [message])
        #expect(store.lastConfirmedSendID == nil)
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
        try await eventually { store.phase.isLive }
        try FileManager.default.removeItem(at: directory)
        try Data("Not a directory".utf8).write(to: directory)
        let id = UUID().uuidString
        await #expect(throws: (any Error).self) { try await store.post(id: id, content: "Preserve this UUID") }
        let first = try #require(store.lastSendFailure)
        #expect(first.messageId == id)
        #expect(first.phase == .notSent)
        #expect(first.error == store.attemptPersistenceError)
        #expect(first.error == store.sendError)
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
        try await eventually { store.phase.isLive }
        await #expect(throws: (any Error).self) { try await store.post(content: "Must not leave without its UUID") }
        #expect(store.attemptPersistenceError != nil)
        #expect(store.lastSendFailure == nil)
        #expect(store.sendAttempts.isEmpty)
        #expect(mock.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}
