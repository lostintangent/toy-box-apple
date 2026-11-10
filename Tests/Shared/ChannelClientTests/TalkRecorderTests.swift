import AVFoundation
import ChannelKit
import Foundation
import Observation
import Testing
@testable import ChannelClient

/// Journeys through a talk note, from the row's swipe to the row settling, with scripted words, the
/// outbox and beats the test ends. See Talk to the Lead in docs/spec.md.
@Suite(.timeLimit(.minutes(1))) @MainActor
struct TalkRecorderTests {
    let recognizer = TalkTestRecognizer()
    let beats: CardBeats
    let checks: CardChecks
    let draft = ComposerDraft(imageIsReadable: { _ in false })
    let channels = ["new", "test", "b", "newer", "a"].map {
        Channel(id: $0, name: $0, model: .init(provider: "test", name: "test"), updatedAt: "")
    }

    init() {
        beats = CardBeats()
        checks = CardChecks(animate: beats.animate, pause: beats.pause)
    }

    @Test func aNoteSendsOnlyItsFinishedWordsOnceAndTalkingAgainFromTheCheckKeepsTheCard() async throws {
        let sentAt = Date(timeIntervalSince1970: 1_793_000_000)
        let server = try await CardServer.start(channels: ["test"], now: sentAt) { post, number in
            try CardServer.accepted(post, keepOpen: number == 1)
        }
        defer { server.end() }
        let store = server.catalog.channel(id: "test")
        draft.text = "My own draft"
        var announcements: [String] = []
        let recorder = try await start(on: store, order: ["a", "test", "b"]) { announcements.append($0) }
        defer { recorder.deactivate() }
        #expect(recorder.isLifted && recorder.hidesTrailingColumn)
        #expect(recorder.timeSlot == .counter)
        #expect(recorder.ordered(channels).map(\.id) == ["a", "test", "b", "new", "newer"],
                "Activity can't move rows beneath the card, and new channels follow in server order")
        #expect(recorder.hiddenLines == ["a", "test", "b"],
                "The lines above and below the held row and under the next row hide, so the card never crosses one")

        recognizer.send("Put the library", isFinal: true)
        recognizer.send("beside", isFinal: false)
        #expect(recorder.finalizedWords == "Put the library")
        #expect(recorder.tentativeWords == " beside")
        recognizer.finalWords = [("beside the desks", true)]
        await recorder.send()
        #expect(server.outbox.messages(in: "test", on: server.catalog.api.baseURL).map(\.text) == ["Put the library beside the desks"],
                "Plain words go to the outbox with no mention")
        #expect(recorder.phase == .sent && !recorder.isLifted && recorder.hidesTrailingColumn,
                "The card closes as soon as the outbox has the note, while it's still sending")
        #expect(beats.motions.last == .sent && recorder.hiddenLines.isEmpty,
                "The lines return as the card starts shrinking, not once it closes")
        #expect(recorder.timeSlot == .noteTime)
        #expect(recorder.sentAt == sentAt, "The row shows the time the note was sent")
        #expect(recorder.isChecked)
        #expect(announcements == ["Sent to Lead in Studio"])
        #expect(draft.text == "My own draft")
        try await eventually(observing: server.mock) { server.mock.pendingResponseCount == 1 }
        server.mock.finishPendingResponses()

        try await beats.end(.seconds(0.35))
        try await eventually { recorder.phase == .landed }
        #expect(!recorder.hidesTrailingColumn)
        recorder.start(store, name: "Studio", order: ["a", "test", "b"])
        #expect(recorder.phase == .recording)
        #expect(recorder.channelID == "test" && checks["test"] == nil,
                "The row stays held, so its card stays up and the check swaps straight to the mic")
        #expect(recorder.finalizedWords.isEmpty && recorder.sentAt == nil)
        #expect(recorder.hiddenLines == ["a", "test", "b"])
        try await eventually { beats.waiting.isEmpty }

        try await eventually { recorder.isListening }
        recognizer.send("And a lamp", isFinal: true)
        await recorder.send()
        try await beats.end(.seconds(0.35))
        try await eventually { recorder.phase == .landed }
        try await beats.end(.seconds(2.35))
        try await eventually { checks["test"] == .settling }
        #expect(recorder.timeSlot == .noteTime && !recorder.isChecked,
                "The note's time stays through the settle, since the row's own time reads the same")
        #expect(recorder.ordered(channels).map(\.id) == ["a", "test", "b", "new", "newer"])
        try await beats.end(.seconds(0.45))
        try await eventually { recorder.phase == nil }
        #expect(recorder.channelID == nil)
        #expect(recorder.ordered(channels).map(\.id) == channels.map(\.id), "Settling lets the row go")
        #expect(beats.motions == [.open, .sent, .settle, .open, .sent, .settle, .settle])
        #expect(announcements.count == 2)
        try await eventually { server.outbox.messages(in: "test", on: server.catalog.api.baseURL).isEmpty }
        #expect(server.posts.map(\.content) == ["Put the library beside the desks", "And a lamp"])
        #expect(Set(server.posts.map(\.id)).count == 2, "Each note is its own message")
    }

    @Test func aNoteThatEndsNotSentWaitsInItsChannelWithRetry() async throws {
        let server = try await CardServer.start(channels: ["test"]) { _, _ in
            MockResponse(status: 422, body: Data(#"{"error":"Reply rejected"}"#.utf8))
        }
        defer { server.end() }
        let store = server.catalog.channel(id: "test")
        var announcements: [String] = []
        let recorder = try await start(on: store, order: ["test", "a"]) { announcements.append($0) }
        defer { recorder.deactivate() }
        recognizer.send("Keep a reading nook", isFinal: true)
        await recorder.send()
        #expect(recorder.phase == .sent && recorder.isChecked && !recorder.isLifted)
        try await eventually { store.sending.map(\.state) == [.notSent] }
        #expect(recorder.phase == .sent && announcements == ["Sent to Lead in Studio"],
                "The card has closed, and the note waits in its channel with Retry")
        #expect(draft.text.isEmpty, "The note stays in the outbox, not the draft")
    }

    @Test(arguments: [false, true])
    func endingANoteNeverPostsAndOnlyLeavingKeepsItsWords(leaves: Bool) async throws {
        let server = try await CardServer.start(channels: ["test"]) { _, _ in
            Issue.record("Ending a note must not post")
            return MockResponse(status: 500)
        }
        defer { server.end() }
        let store = server.catalog.channel(id: "test")
        draft.text = "An earlier draft"
        let recorder = try await start(on: store)
        defer { recorder.deactivate() }
        recognizer.send("Put the library", isFinal: true)
        recognizer.send("by the desks", isFinal: false)
        if leaves { recorder.leave() } else { recorder.cancel() }
        #expect(!recorder.isLifted)
        #expect(recognizer.isCancelled)
        let kept = leaves ? "An earlier draft\n\nPut the library by the desks" : "An earlier draft"
        #expect(draft.text == kept)
        recognizer.send("Late words", isFinal: true)
        #expect(draft.text == kept)
        #expect(server.posts.isEmpty && server.outbox.messages(in: "test", on: server.catalog.api.baseURL).isEmpty)
    }

    @Test func theCardStaysOnItsRowAndGrowsUpOnlyOnceItsBottomMeetsTheRooms() {
        let room = CGRect(x: 0, y: 8, width: 390, height: 600)
        let middle = CardPlacement(row: CGRect(x: 0, y: 200, width: 390, height: 72), room: room)
        #expect([72, 190, 330].map(middle.top(height:)) == [200, 200, 200], "A row with room below never moves")

        let bottom = CardPlacement(row: CGRect(x: 0, y: 500, width: 390, height: 72), room: room)
        #expect(bottom.top(height: 108) == 500, "The card stays on its row while it fits below")
        #expect(bottom.top(height: 190) == 418, "Then it holds its bottom on the room's and grows up")
        #expect(bottom.top(height: 330) == 278)
        #expect(bottom.top(height: 700) == 8, "It never rises past the room's top")

        let scrolledUnder = CardPlacement(row: CGRect(x: 0, y: 0, width: 390, height: 72), room: room)
        #expect(scrolledUnder.top(height: 700) == 0, "A row under the room's top is never pushed down")
    }

    /// Opens the recorder on the store's row, as the swipe does, once it's listening.
    private func start(on store: ChannelStore, order: [String] = [],
                       announce: @escaping @MainActor (String) -> Void = { _ in }) async throws -> TalkRecorder {
        var system = DictationSystem.scripted()
        system.makeRecognizer = { [recognizer] _, _, _ in recognizer }
        system.refreshNotifications = []
        let draft = draft
        let recorder = TalkRecorder(system: system, checks: checks, draft: { _ in draft }, announce: announce,
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

/// Holds each pause in a card's motion until the test ends it, and logs each beat's motion.
@MainActor @Observable final class CardBeats {
    private(set) var waiting: [Duration] = []
    private(set) var motions: [CardMotion] = []
    @ObservationIgnored private var held: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    func animate(_ motion: CardMotion, _ change: () -> Void) {
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

    /// Waits until a pause of `duration` is waiting, then ends the earliest one.
    func end(_ duration: Duration) async throws {
        try await eventually { waiting.contains(duration) }
        end(held[waiting.firstIndex(of: duration)!].id)
    }

    private func end(_ id: UUID) {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index)
        held.remove(at: index).continuation.resume()
    }
}
