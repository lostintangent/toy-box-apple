import ChannelClient
import ChannelKit
import Foundation
import Observation
import SwiftUI
import UIKit

/// Swipe to talk: one spoken note from the channel list to that channel's Lead, without opening
/// the channel. One recorder serves the whole list, and one row uses it at a time. See Talk to the
/// Lead in docs/spec.md.
@MainActor @Observable
final class TalkRecorder: DictationTextTarget {
    enum Phase: Equatable {
        /// Listening, paused or getting ready, with the row grown into the recorder.
        case recording
        case sending
        /// The note stays in the channel's outbox under its UUID, so Send Again can't post it twice.
        case failed(ChannelSendPhase)
        /// The card shrinking back into the row as the mic becomes the done check.
        case sent
        /// The card has landed, and the row wears the done check for two seconds.
        case landed
        /// The row easing back to the channel's mark after the check or Cancel.
        case settling
    }

    /// The held row's frame in the window, and how far before its trailing edge the row's text
    /// ends, which is the time's trailing edge unless the time leads its own line.
    struct Cell: Equatable {
        var frame: CGRect
        var textInset: CGFloat = 0
    }

    enum TimeFace: Hashable {
        case counter, offline, failed(ChannelSendPhase), noteTime
    }

    let dictation: ComposerDictation
    private(set) var channelID: String?
    private(set) var channelName = ""
    private(set) var phase: Phase?
    /// Earlier listening sessions in this note, since a pause ends the dictation session.
    private(set) var committed = ""
    private(set) var transcript = DictationTranscript()
    /// The voice level, newest first, sampled about 12 times a second while listening.
    private(set) var levels: [Double] = []
    /// True once a send has gone 300 ms without confirming.
    private(set) var showsProgress = false
    private(set) var listeningSince: Date?
    /// The held row in the window, which the card opens on and returns to.
    var cell: Cell?
    /// When the server committed the note, which the row shows as its time until it settles.
    private(set) var sentAt: Date?
    /// The list's order when the note began, held until the row settles so the sent note's
    /// activity can't move its row mid-beat.
    private(set) var order: [String]?
    @ObservationIgnored private var listened: TimeInterval = 0
    @ObservationIgnored private var store: ChannelStore?
    @ObservationIgnored private weak var catalog: ChannelCatalogStore?
    @ObservationIgnored private var attempt: (id: String, words: String)?
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private let draft: @MainActor (ChannelStore) -> ComposerDraft
    @ObservationIgnored private let announce: @MainActor (String) -> Void

    static let sampleCount = 64

    init(system: DictationSystem = .live,
         draft: @escaping @MainActor (ChannelStore) -> ComposerDraft = TalkRecorder.sharedDraft,
         announce: @escaping @MainActor (String) -> Void = { UIAccessibility.post(notification: .announcement, argument: $0) }) {
        dictation = ComposerDictation(system: system)
        self.draft = draft
        self.announce = announce
        dictation.target = self
    }

    static func sharedDraft(for store: ChannelStore) -> ComposerDraft {
        .shared(serverURL: store.api.baseURL, channelID: store.id, imageIsReadable: ComposerSession.imageIsReadable)
    }

    /// Talk shows only where dictation supports the person's language.
    var isAvailable: Bool { dictation.availability != .checking && dictation.availability != .unsupported }

    /// True while the recorder holds the list, which dims every other row.
    var isOpen: Bool {
        switch phase {
        case .recording, .sending, .failed: true
        case .sent, .landed, .settling, nil: false
        }
    }

    /// What the row's time slot shows in place of the time, until the row settles.
    var timeFace: TimeFace? {
        switch phase {
        case .recording, .sending: isOffline ? .offline : .counter
        case .failed(let failure): .failed(failure)
        case .sent, .landed: .noteTime
        case .settling, nil: nil
        }
    }

    /// The chevron and attention mark stay hidden until the card has landed.
    var hidesTrailingColumn: Bool {
        switch phase {
        case .recording, .sending, .failed, .sent: true
        case .landed, .settling, nil: false
        }
    }

    var isListening: Bool { phase == .recording && dictation.phase == .listening }

    /// Words the transcriber has finalized, which are all Send ever posts.
    var finalizedWords: String { DictationTranscript.join(committed, transcript.finalized) }

    /// The current guess after the finalized words, shown in secondary ink until it settles.
    var tentativeWords: String {
        let finalized = finalizedWords
        return String(DictationTranscript.join(finalized, transcript.tentative).dropFirst(finalized.count))
    }

    var isOffline: Bool {
        guard let catalog else { return false }
        if case .failed = catalog.phase { return true }
        return false
    }

    var canSend: Bool {
        switch phase {
        case .recording:
            dictation.phase != .finishing && !isOffline
                && !finalizedWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .failed: !isOffline
        default: false
        }
    }

    /// The mic offers Resume once listening stops, after silence, a failure or with access off.
    var canResume: Bool { phase == .recording && dictation.phase == .idle }

    func elapsed(at date: Date) -> TimeInterval {
        listened + (listeningSince.map { max(date.timeIntervalSince($0), 0) } ?? 0)
    }

    /// Channels in the order they had when the note began, with any new ones after them.
    func ordered(_ channels: [Channel]) -> [Channel] {
        guard let order else { return channels }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return channels.enumerated()
            .sorted { (rank[$0.element.id] ?? order.count + $0.offset, $0.offset)
                < (rank[$1.element.id] ?? order.count + $1.offset, $1.offset) }
            .map(\.element)
    }

    /// Checks the language only, so Talk can show without touching the microphone.
    func activate() { dictation.activate() }

    func deactivate() {
        leave()
        dictation.deactivate()
    }

    /// Opens the recorder on the channel's row and starts listening.
    func start(_ store: ChannelStore, name: String, contextualNames: [String] = [],
               catalog: ChannelCatalogStore? = nil, order: [String] = []) {
        guard isAvailable, !isOpen else { return }
        // Talking again on a row that still wears the check keeps its card, so the check swaps
        // straight to the mic.
        if phase != nil { close(keepingCell: channelID == store.id) }
        self.store = store
        self.catalog = catalog
        self.order = order
        attempt = nil
        committed = ""
        transcript = .init()
        levels = Array(repeating: 0, count: Self.sampleCount)
        listened = 0
        listeningSince = nil
        dictation.contextualStrings = ["Lead"] + contextualNames
        withAnimation(Self.motion(.open)) {
            channelID = store.id
            channelName = name
            phase = .recording
        }
        follow()
        dictation.toggleRecheckingInput()
    }

    /// The mic's Resume.
    func resume() {
        guard canResume else { return }
        dictation.toggleRecheckingInput()
    }

    /// Sends the finalized words as a new message to the Lead, or repeats a failed attempt.
    func send() async {
        guard canSend, let store else { return }
        if case .failed = phase { return await deliver(to: store) }
        phase = .sending
        if dictation.isSessionActive {
            let finalized = await dictation.stop(.send)
            guard phase == .sending, self.store === store else { return }
            guard finalized else {
                phase = .recording
                return
            }
        } else if dictation.phase != .idle {
            dictation.leaveDraft()
        }
        let words = finalizedWords.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            phase = .recording
            return
        }
        dictation.draftSent()
        attempt = (UUID().uuidString, words)
        await deliver(to: store)
    }

    private func deliver(to store: ChannelStore) async {
        guard let attempt else { return }
        phase = .sending
        let progress = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, phase == .sending else { return }
            showsProgress = true
        }
        defer {
            progress.cancel()
            showsProgress = false
        }
        do {
            let result = try await store.postInBackground(id: attempt.id, content: attempt.words)
            guard self.store === store, self.attempt?.id == attempt.id else { return }
            sentAt = if case .committed(let message) = result {
                (try? Date(message.timestamp, strategy: .iso8601)) ?? .now
            } else { .now }
            withAnimation(Self.motion(.sent)) { phase = .sent }
            announce("Sent to Lead in \(channelName)")
            settleAfterSent()
        } catch {
            guard self.store === store, self.attempt?.id == attempt.id else { return }
            let failure: ChannelSendPhase =
                store.sendAttempts.first { $0.id == attempt.id }?.phase == .deliveryNotConfirmed
                ? .deliveryNotConfirmed : .notSent
            phase = .failed(failure)
            announce(failure.label)
        }
    }

    /// Lands the card as its shrink ends, then holds the check for two seconds before settling.
    private func settleAfterSent() {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.35))
            guard let self, !Task.isCancelled, phase == .sent else { return }
            withAnimation(Self.motion(.land)) { phase = .landed }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, phase == .landed else { return }
            settle(Self.motion(.settle))
        }
    }

    /// Eases the row back, then ends the note once the row has settled.
    private func settle(_ animation: Animation) {
        withAnimation(animation) { phase = .settling }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.45))
            guard let self, !Task.isCancelled, phase == .settling else { return }
            close()
        }
    }

    /// Discards a note nothing has sent, and closes the row with the open spring in reverse. After a
    /// failure, the note stays in the channel's outbox, where the conversation offers Send Again like
    /// any failed send.
    func cancel() {
        switch phase {
        case .recording, .failed:
            following?.cancel()
            sampling?.cancel()
            listeningSince = nil
            dictation.leaveDraft()
            settle(Self.motion(.open))
        case .sending, .sent, .landed, .settling, nil:
            break
        }
    }

    /// Ends the note when something takes the person away from the list. Words still being
    /// recorded become the channel's draft, after any draft already there.
    func leave() {
        switch phase {
        case .recording:
            dictation.commitNow()
            let words = finalizedWords.trimmingCharacters(in: .whitespacesAndNewlines)
            if let store, !words.isEmpty {
                let draft = draft(store)
                draft.text = ComposerDraft.joined(draft.text, words)
            }
            close()
        case .sending, .failed, .sent, .landed, .settling:
            close()
        case nil:
            break
        }
    }

    private func close(keepingCell: Bool = false) {
        phase = nil
        channelID = nil
        if !keepingCell { cell = nil }
        sentAt = nil
        order = nil
        following?.cancel()
        sampling?.cancel()
        settling?.cancel()
        dictation.leaveDraft()
        store = nil
        attempt = nil
        committed = ""
        transcript = .init()
        listeningSince = nil
        showsProgress = false
    }

    /// Times listening and samples the voice level, so a pause stops the counter and rests the waveform.
    private func follow() {
        following?.cancel()
        following = Task { [weak self, dictation] in
            for await listening in Observations({ dictation.phase == .listening }) {
                guard let self, !Task.isCancelled else { return }
                listeningChanged(listening)
            }
        }
    }

    private func listeningChanged(_ listening: Bool) {
        guard phase != nil, listening != (listeningSince != nil) else { return }
        if listening {
            listeningSince = .now
            sampling?.cancel()
            sampling = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    levels.insert(dictation.level, at: 0)
                    levels.removeLast(max(levels.count - Self.sampleCount, 0))
                    try? await Task.sleep(for: .milliseconds(83))
                }
            }
        } else {
            listened = elapsed(at: .now)
            listeningSince = nil
            sampling?.cancel()
            levels = Array(repeating: 0, count: Self.sampleCount)
        }
    }

    // MARK: DictationTextTarget

    var isInKeyWindow: Bool { phase == .recording }

    func beginDictation() -> Bool { phase == .recording }

    func showDictation(_ transcript: DictationTranscript) {
        guard phase == .recording || phase == .sending else { return }
        self.transcript = transcript
    }

    func endDictation(_ finalized: String) {
        guard phase == .recording || phase == .sending else { return }
        committed = DictationTranscript.join(committed, finalized)
        transcript = .init()
    }

    // MARK: Motion

    enum Motion { case open, sent, land, settle }

    /// The spec's springs, or short eases without bounce under Reduce Motion.
    static func motion(_ motion: Motion) -> Animation {
        if UIAccessibility.isReduceMotionEnabled { return .easeInOut(duration: 0.2) }
        return switch motion {
        case .open: .spring(duration: 0.4, bounce: 0.12)
        case .sent: .smooth(duration: 0.35)
        case .land, .settle: .easeOut(duration: 0.4)
        }
    }
}
