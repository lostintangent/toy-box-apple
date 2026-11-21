import ToyBoxKit
import Foundation
import Observation

/// Swipe to talk: one spoken note from the channel list to that channel's Lead, without opening
/// the channel. One recorder serves the whole list, and one row uses it at a time. A note goes to
/// the outbox, so the card closes with its check as soon as it's saved. It holds the note's rules,
/// and the app draws it and supplies its motion. See Talk to the Lead in docs/spec.md.
@MainActor @Observable
package final class TalkRecorder: DictationTextTarget {
    package enum Phase: Equatable {
        /// Listening, paused or getting ready, with the row grown into the recorder.
        case recording
        /// The transcriber finishing its last words, then the outbox saving the note.
        case sending
        /// The card shrinking back into the row like Cancel's, while the mic becomes the done check.
        case sent
        /// The card has landed, and stays on its row until the row's check settles.
        case landed
        /// The card easing back into its row after Cancel.
        case cancelled
    }

    package enum TimeSlot: Hashable {
        case counter, offline
    }

    package let dictation: Dictation
    /// The held row's channel, on its server.
    package private(set) var target: ChannelTarget?
    package private(set) var channelName = ""
    package private(set) var phase: Phase?
    /// Earlier listening sessions in this note, since a pause ends the dictation session.
    package private(set) var committed = ""
    package private(set) var transcript = DictationTranscript()
    /// The voice level, newest first, sampled about 12 times a second while listening.
    package private(set) var levels: [Double] = []
    package private(set) var listeningSince: Date?
    /// The list's order when the note began, held until the row settles so the sent note's
    /// activity can't move its row mid-beat.
    package private(set) var order: [ChannelTarget]?
    @ObservationIgnored private var listened: TimeInterval = 0
    @ObservationIgnored private var store: ChannelStore?
    @ObservationIgnored private weak var catalog: ChannelCatalogStore?
    @ObservationIgnored private let checks: CardChecks
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private let draft: @MainActor (ChannelStore) -> ComposerDraft
    @ObservationIgnored private let announce: @MainActor (String) -> Void

    package static let sampleCount = 64
    /// How long the open spring takes to bring the card back down onto its row. The check settles
    /// two seconds later.
    private static let landing = Duration.seconds(0.45)

    /// - Parameters:
    ///   - checks: The list's done checks, which the row wears once its note sends, and the cards' motion.
    ///   - draft: The channel's composer draft, which keeps the words of a note left mid-way.
    ///   - announce: Speaks a VoiceOver announcement.
    package init(system: DictationSystem, checks: CardChecks,
                 draft: @escaping @MainActor (ChannelStore) -> ComposerDraft,
                 announce: @escaping @MainActor (String) -> Void = CardMotion.announce) {
        dictation = Dictation(system: system)
        self.checks = checks
        self.draft = draft
        self.announce = announce
        dictation.target = self
    }

    /// Talk shows only where dictation supports the person's language.
    package var isAvailable: Bool { dictation.availability != .checking && dictation.availability != .unsupported }

    /// True while the card is lifted above the list, which holds still with every other row dimmed.
    package var isLifted: Bool {
        switch phase {
        case .recording, .sending: true
        case .sent, .landed, .cancelled, nil: false
        }
    }

    /// True while the held row wears the done check, from the note's Send until the check settles.
    package var isChecked: Bool {
        guard phase == .sent || phase == .landed, let target else { return false }
        return checks[target] == .sent
    }

    /// What the row's time slot shows in place of the time while the card is lifted. As the card
    /// closes, on Send or Cancel, the slot swaps back to the row's own time.
    package var timeSlot: TimeSlot? {
        guard isLifted else { return nil }
        return isOffline ? .offline : .counter
    }

    /// The rows whose bottom line the open card covers: the held row, the row above it, whose line
    /// is the held row's top, and the row below it, so the card never crosses a line. The lines
    /// return in the shrink's own transaction, on Send and on Cancel.
    package var hiddenLines: Set<ChannelTarget> {
        guard isLifted, let held = target else { return [] }
        guard let order, let index = order.firstIndex(of: held) else { return [held] }
        return Set(order[max(index - 1, 0)...min(index + 1, order.count - 1)])
    }

    /// The chevron and attention mark stay hidden until the card has landed.
    package var hidesTrailingColumn: Bool {
        switch phase {
        case .recording, .sending, .sent: true
        case .landed, .cancelled, nil: false
        }
    }

    package var isListening: Bool { phase == .recording && dictation.phase == .listening }

    /// Words the transcriber has finalized, which are all Send ever posts.
    package var finalizedWords: String { DictationTranscript.join(committed, transcript.finalized) }

    /// The current guess after the finalized words, shown in secondary ink until it settles.
    package var tentativeWords: String {
        let finalized = finalizedWords
        return String(DictationTranscript.join(finalized, transcript.tentative).dropFirst(finalized.count))
    }

    package var isOffline: Bool { catalog?.phase.failure != nil }

    /// Send turns on with the first word shown, even a guess, and its send waits for the final result.
    package var canSend: Bool {
        phase == .recording && dictation.phase != .finishing && !isOffline && store?.outbox != nil
            && !(finalizedWords + tentativeWords).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The mic offers Resume once listening stops, after silence, a failure or with access off.
    package var canResume: Bool { phase == .recording && dictation.phase == .idle }

    package func elapsed(at date: Date) -> TimeInterval {
        listened + (listeningSince.map { max(date.timeIntervalSince($0), 0) } ?? 0)
    }

    /// A server's channels in the order they had when the note began, with any new ones after them.
    package func ordered(_ channels: [Channel], on server: URL) -> [Channel] {
        guard let order else { return channels }
        let ranks = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked = channels.enumerated().map { offset, channel in
            let target = ChannelTarget(serverURL: server.absoluteString, channelID: channel.id)
            return (rank: target.flatMap { ranks[$0] } ?? order.count + offset, offset: offset, channel: channel)
        }
        return ranked.sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }.map(\.channel)
    }

    package func deactivate() {
        leave()
        dictation.deactivate()
    }

    /// Opens the recorder on the channel's row and starts listening. `order` is the list's
    /// channels, top to bottom.
    package func start(_ store: ChannelStore, name: String, contextualNames: [String] = [],
                       catalog: ChannelCatalogStore? = nil, order: [ChannelTarget] = []) {
        guard isAvailable, !isLifted, let target = store.target else { return }
        if phase != nil { close() }
        self.store = store
        self.catalog = catalog
        self.order = order
        committed = ""
        transcript = .init()
        levels = Array(repeating: 0, count: Self.sampleCount)
        listened = 0
        listeningSince = nil
        dictation.contextualStrings = ["Lead"] + contextualNames
        checks.animate(.open) {
            self.target = target
            channelName = name
            phase = .recording
        }
        follow()
        dictation.toggleRecheckingInput()
    }

    /// The mic's Resume.
    package func resume() {
        guard canResume else { return }
        dictation.toggleRecheckingInput()
    }

    /// Sends the finalized words as a new message to the Lead.
    package func send() async {
        guard canSend, let store, let outbox = store.outbox, let target else { return }
        phase = .sending
        let finalized = await dictation.stop(.send)
        guard phase == .sending, self.store === store else { return }
        let words = finalizedWords.trimmingCharacters(in: .whitespacesAndNewlines)
        guard finalized, !words.isEmpty else {
            phase = .recording
            return
        }
        await outbox.send(words, to: store.id, on: store.api.baseURL)
        guard phase == .sending, self.store === store else { return }
        // The card closes with Cancel's spring, and lands as Cancel's does.
        checks.animate(.open) {
            phase = .sent
            checks.sent(target, settlingAfter: .seconds(2.45))
        }
        announce("Sent to Lead in \(channelName)")
        land(target)
    }

    /// Lands the card as its shrink ends, then ends the note once its row's check has settled.
    private func land(_ target: ChannelTarget) {
        closing?.cancel()
        closing = Task { [weak self] in
            await self?.checks.pause(Self.landing)
            guard let self, !Task.isCancelled, phase == .sent else { return }
            checks.animate(.settle) { phase = .landed }
            for await check in Observations({ [checks] in checks[target] }) where check == nil { break }
            guard !Task.isCancelled, phase == .landed else { return }
            close()
        }
    }

    /// Discards a note nothing has sent, and closes the row with the open spring in reverse.
    package func cancel() {
        guard phase == .recording else { return }
        following?.cancel()
        sampling?.cancel()
        // The counter keeps its last time while it leaves.
        listened = elapsed(at: .now)
        listeningSince = nil
        dictation.leaveDraft()
        checks.animate(.open) { phase = .cancelled }
        closing?.cancel()
        closing = Task { [weak self] in
            await self?.checks.pause(Self.landing)
            guard let self, !Task.isCancelled, phase == .cancelled else { return }
            close()
        }
    }

    /// Ends the note when something takes the person away from the list. Words still being
    /// recorded become the channel's draft, after any draft already there.
    package func leave() {
        guard phase != nil else { return }
        if phase == .recording {
            dictation.commitNow()
            if let store { draft(store).append(finalizedWords) }
        }
        close()
    }

    private func close() {
        // A sent note's check leaves with its card, and talking again swaps it straight to the mic.
        if phase == .sent || phase == .landed, let target { checks.clear(target) }
        phase = nil
        target = nil
        order = nil
        following?.cancel()
        sampling?.cancel()
        closing?.cancel()
        dictation.leaveDraft()
        store = nil
        committed = ""
        transcript = .init()
        listeningSince = nil
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

    package var isInKeyWindow: Bool { phase == .recording }

    package func beginDictation() -> Bool { phase == .recording }

    package func showDictation(_ transcript: DictationTranscript) {
        guard phase == .recording || phase == .sending else { return }
        self.transcript = transcript
    }

    package func endDictation(_ finalized: String) {
        guard phase == .recording || phase == .sending else { return }
        committed = DictationTranscript.join(committed, finalized)
        transcript = .init()
    }
}
