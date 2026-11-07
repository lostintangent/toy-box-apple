import AVFoundation
import ChannelKit
import Foundation
import Observation
import Synchronization
import Testing
@testable import ChannelClient

/// Journeys through a talk note, from the row's swipe to the row settling, with scripted words, a
/// mock server and beats the test ends. See Talk to the Lead in docs/spec.md.
@Suite(.timeLimit(.minutes(1))) @MainActor
struct TalkRecorderTests {
    struct Posted: Decodable { var id: String; var content: String }
    struct MessageEnvelope: Encodable { var version = 1; var message: ChannelMessage }

    let recognizer = TalkTestRecognizer()
    let beats = TalkBeats()
    let draft = ComposerDraft(imageIsReadable: { _ in false })
    let channels = ["new", "test", "b", "newer", "a"].map {
        Channel(id: $0, name: $0, model: .init(provider: "test", name: "test"), updatedAt: "")
    }

    @Test func aNoteSendsOnlyItsFinishedWordsOnceAndTalkingAgainFromTheCheckKeepsTheCard() async throws {
        let posts = Mutex<[Posted]>([])
        let mock = MockTransport { request, _ in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/v1/channels/test/messages")
            let body = try JSONDecoder().decode(Posted.self, from: requestBody(request))
            posts.withLock { $0.append(body) }
            let message = ChannelMessage(id: body.id, sequence: 42, timestamp: "2026-10-27T00:00:00Z",
                                         sender: .user, content: .text(body.content))
            return try .json(MessageEnvelope(message: message), status: 201)
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        draft.text = "My own draft"
        var announcements: [String] = []
        let recorder = try await start(on: store, order: ["a", "test", "b"]) { announcements.append($0) }
        defer { recorder.deactivate() }
        let cell = TalkRecorder.Cell(frame: CGRect(x: 20, y: 120, width: 356, height: 72), textInset: 13)
        recorder.cell = cell
        recorder.isGrown = true
        #expect(recorder.isOpen && recorder.hidesTrailingColumn)
        #expect(recorder.timeFace == .counter)
        #expect(recorder.ordered(channels).map(\.id) == ["a", "test", "b", "new", "newer"],
                "Activity can't move rows beneath the card, and new channels follow in server order")
        #expect(lines(hiddenBy: recorder) == ["a", "test", "b"],
                "The lines above and below the held row and under the next row hide, so the card never crosses one")

        recognizer.send("Put the library", isFinal: true)
        recognizer.send("beside", isFinal: false)
        #expect(recorder.finalizedWords == "Put the library")
        #expect(recorder.tentativeWords == " beside")
        #expect(recorder.rowValue(details: "Now") == "Recording")
        recognizer.finalWords = [("beside the desks", true)]
        await recorder.send()
        #expect(posts.withLock { $0.map(\.content) } == ["Put the library beside the desks"],
                "Plain words reach the Lead with no mention or request answer")
        #expect(recorder.phase == .sent && !recorder.isOpen && recorder.hidesTrailingColumn)
        #expect(beats.motions.last == .sent && lines(hiddenBy: recorder).isEmpty,
                "The lines return as the card starts shrinking, not once it closes")
        #expect(recorder.timeFace == .noteTime)
        #expect(recorder.sentAt == (try? Date("2026-10-27T00:00:00Z", strategy: .iso8601)),
                "The row shows the server's time for the note")
        #expect(recorder.rowValue(details: "Now") == "Sent to Lead. Now")
        #expect(announcements == ["Sent to Lead in Studio"])
        #expect(draft.text == "My own draft")

        try await beats.end(.seconds(0.35))
        try await eventually { recorder.phase == .landed }
        #expect(!recorder.hidesTrailingColumn)
        recorder.start(store, name: "Studio", order: ["a", "test", "b"])
        #expect(recorder.phase == .recording)
        #expect(recorder.cell == cell && recorder.isGrown, "The card stays up, so the check swaps straight to the mic")
        #expect(recorder.finalizedWords.isEmpty && recorder.sentAt == nil)
        #expect(lines(hiddenBy: recorder) == ["a", "test", "b"])
        try await eventually { beats.waiting.isEmpty }

        try await eventually { recorder.isListening }
        recognizer.send("And a lamp", isFinal: true)
        await recorder.send()
        let sent = posts.withLock { $0 }
        #expect(sent.map(\.content).last == "And a lamp")
        #expect(Set(sent.map(\.id)).count == 2, "Each note is its own message")
        try await beats.end(.seconds(0.35))
        try await beats.end(.seconds(2))
        try await eventually { recorder.phase == .settling }
        #expect(recorder.timeFace == nil && recorder.rowValue(details: "Now") == "Now")
        #expect(recorder.ordered(channels).map(\.id) == ["a", "test", "b", "new", "newer"])
        try await beats.end(.seconds(0.45))
        try await eventually { recorder.phase == nil }
        #expect(recorder.cell == nil && !recorder.isGrown)
        #expect(recorder.ordered(channels).map(\.id) == channels.map(\.id), "Settling lets the row go")
        #expect(beats.motions == [.open, .sent, .land, .open, .sent, .land, .settle])
        #expect(announcements.count == 2)
        #expect(store.sendAttempts.isEmpty)
    }

    @Test(arguments: [false, true])
    func aFailedNoteStaysOpenAndSendAgainRepeatsItsAttempt(rejected: Bool) async throws {
        let ids = Mutex<[String]>([])
        let mock = MockTransport { request, _ in
            ids.withLock { $0.append((try? JSONDecoder().decode(Posted.self, from: requestBody(request)))?.id ?? "") }
            if !rejected { throw URLError(.timedOut) }
            return MockResponse(status: 422, body: Data(#"{"error":"Reply rejected"}"#.utf8))
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        var announcements: [String] = []
        let recorder = try await start(on: store, order: ["test", "a"]) { announcements.append($0) }
        defer { recorder.deactivate() }
        recognizer.send("Keep a reading nook", isFinal: true)
        await recorder.send()
        let failure: ChannelSendPhase = rejected ? .notSent : .deliveryNotConfirmed
        #expect(recorder.phase == .failed(failure))
        #expect(recorder.isOpen && recorder.canSend && recorder.timeFace == .failed(failure))
        #expect(recorder.rowValue(details: "Now") == failure.label)
        #expect(lines(hiddenBy: recorder) == ["test", "a"], "The first row has no line above to hide")

        await recorder.send()
        #expect(recorder.phase == .failed(failure))
        let posted = ids.withLock { $0 }
        #expect(posted.count == 2 && Set(posted).count == 1, "Send Again reuses the note's UUID")
        #expect(announcements == [failure.label, failure.label])

        recorder.cancel()
        #expect(recorder.phase == .settling && !recorder.isOpen)
        #expect(lines(hiddenBy: recorder).isEmpty, "Cancel brings the lines back as the card starts shrinking")
        try await beats.end(.seconds(0.45))
        try await eventually { recorder.phase == nil }
        #expect(beats.motions == [.open, .open])
        #expect(draft.text.isEmpty, "The failed note stays in the outbox, not the draft")
        #expect(store.sendAttempts.map(\.id) == [posted[0]])
    }

    @Test(arguments: [false, true])
    func endingANoteNeverPostsAndOnlyLeavingKeepsItsWords(leaves: Bool) async throws {
        let mock = MockTransport { _, _ in
            Issue.record("Ending a note must not post")
            return MockResponse(status: 500)
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        draft.text = "An earlier draft"
        let recorder = try await start(on: store)
        defer { recorder.deactivate() }
        recognizer.send("Put the library", isFinal: true)
        recognizer.send("by the desks", isFinal: false)
        if leaves { recorder.leave() } else { recorder.cancel() }
        #expect(!recorder.isOpen)
        #expect(recognizer.isCancelled)
        let kept = leaves ? "An earlier draft\n\nPut the library by the desks" : "An earlier draft"
        #expect(draft.text == kept)
        recognizer.send("Late words", isFinal: true)
        #expect(draft.text == kept)
        #expect(mock.requests.isEmpty)
        #expect(store.sendAttempts.isEmpty)
    }

    /// The channels whose row hides the line under it.
    private func lines(hiddenBy recorder: TalkRecorder) -> Set<String> {
        Set(channels.map(\.id).filter(recorder.hidesLine(under:)))
    }

    @Test func theCardStaysOnItsRowAndGrowsUpOnlyOnceItsBottomMeetsTheRooms() {
        let room = CGRect(x: 0, y: 8, width: 390, height: 600)
        let middle = TalkRecorder.Placement(row: CGRect(x: 0, y: 200, width: 390, height: 72), room: room)
        #expect([72, 190, 330].map(middle.top(height:)) == [200, 200, 200], "A row with room below never moves")

        let bottom = TalkRecorder.Placement(row: CGRect(x: 0, y: 500, width: 390, height: 72), room: room)
        #expect(bottom.top(height: 108) == 500, "The card stays on its row while it fits below")
        #expect(bottom.top(height: 190) == 418, "Then it holds its bottom on the room's and grows up")
        #expect(bottom.top(height: 330) == 278)
        #expect(bottom.top(height: 700) == 8, "It never rises past the room's top")

        let scrolledUnder = TalkRecorder.Placement(row: CGRect(x: 0, y: 0, width: 390, height: 72), room: room)
        #expect(scrolledUnder.top(height: 700) == 0, "A row under the room's top is never pushed down")
    }

    /// Opens the recorder on the store's row, as the swipe does, once it's listening.
    private func start(on store: ChannelStore, order: [String] = [],
                       announce: @escaping @MainActor (String) -> Void = { _ in }) async throws -> TalkRecorder {
        var system = DictationSystem.scripted()
        system.makeRecognizer = { [recognizer] _, _, _ in recognizer }
        system.refreshNotifications = []
        let draft = draft
        let recorder = TalkRecorder(system: system, draft: { _ in draft }, announce: announce,
                                    animate: beats.animate, pause: beats.pause)
        await recorder.dictation.refreshLanguageSupport()
        recorder.start(store, name: "Studio", order: order)
        try await eventually { recorder.isListening }
        return recorder
    }
}

/// Words the test speaks into the recorder, and the final pass Send waits for.
@MainActor final class TalkTestRecognizer: DictationRecognizing {
    var finalWords: [(String, Bool)] = []
    private(set) var isCancelled = false
    private var result: (@MainActor (String, Bool) -> Void)?

    func start(onListening: @escaping @MainActor () -> Void,
               onResult: @escaping @MainActor (String, Bool) -> Void,
               onLevel: @escaping @MainActor @Sendable (Double) -> Void,
               onInterruption: @escaping @MainActor @Sendable () -> Void,
               onFailure: @escaping @MainActor (any Error) -> Void) async throws {
        result = onResult
        onListening()
    }

    func send(_ text: String, isFinal: Bool) { result?(text, isFinal) }

    func finish() async throws {
        for (text, isFinal) in finalWords { result?(text, isFinal) }
        finalWords = []
    }

    func cancel() { isCancelled = true }
}

/// Holds each pause in the card's motion until the test ends it, and logs each beat's motion.
@MainActor @Observable final class TalkBeats {
    private(set) var waiting: [Duration] = []
    private(set) var motions: [TalkRecorder.Motion] = []
    @ObservationIgnored private var held: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    func animate(_ motion: TalkRecorder.Motion, _ change: () -> Void) {
        change()
        motions.append(motion)
    }

    func pause(_ duration: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                held.append((id, continuation))
                waiting.append(duration)
            }
        } onCancel: {
            Task { @MainActor in self.end(id) }
        }
    }

    /// Waits until the next pause is `duration`, then ends it.
    func end(_ duration: Duration) async throws {
        try await eventually { waiting.first == duration }
        end(held[0].id)
    }

    private func end(_ id: UUID) {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index)
        held.remove(at: index).continuation.resume()
    }
}
