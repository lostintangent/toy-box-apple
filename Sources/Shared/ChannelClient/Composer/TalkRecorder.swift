import ChannelKit
import Foundation
import Observation

/// Swipe to talk: one spoken note from the channel list to that channel's Lead, without opening
/// the channel. One recorder serves the whole list, and one row uses it at a time. It holds the
/// note's rules, and the app draws it and supplies its motion. See Talk to the Lead in docs/spec.md.
@MainActor @Observable
package final class TalkRecorder: DictationTextTarget {
    package enum Phase: Equatable {
        /// Listening, paused or getting ready, with the row grown into the recorder.
        case recording
        case sending
        /// The note stays in the channel's outbox under its UUID, so Send Again can't post it twice.
        case failed(ChannelSendPhase)
        /// The card shrinking back into the row as the mic becomes the done check.
        case sent
        /// The card has landed, and stays on its row until the row's check settles.
        case landed
        /// The card easing back into its row after Cancel.
        case cancelled
    }

    /// The held row's frame in the window, and how far before its trailing edge the row's text
    /// ends, which is the time's trailing edge unless the time leads its own line.
    package struct Cell: Equatable {
        package var frame: CGRect
        package var textInset: CGFloat = 0

        package init(frame: CGRect, textInset: CGFloat = 0) {
            self.frame = frame
            self.textInset = textInset
        }
    }

    package enum TimeSlot: Hashable {
        case counter, offline, failed(ChannelSendPhase), noteTime
    }

    package let dictation: ComposerDictation
    package private(set) var channelID: String?
    package private(set) var channelName = ""
    package private(set) var phase: Phase?
    /// Earlier listening sessions in this note, since a pause ends the dictation session.
    package private(set) var committed = ""
    package private(set) var transcript = DictationTranscript()
    /// The voice level, newest first, sampled about 12 times a second while listening.
    package private(set) var levels: [Double] = []
    /// When the note's attempt began posting, which Send's progress waits 300 ms from.
    package private(set) var postingSince: ContinuousClock.Instant?
    package private(set) var listeningSince: Date?
    /// The held row in the window, which the card opens on and returns to.
    package var cell: Cell?
    /// True once the card has grown from the row. The card's growth, every slot's swap and the
    /// list's dim follow it, so they run in the card's own spring, since the swipe action's
    /// transaction doesn't animate.
    package var isGrown = false
    /// When the server committed the note, which the row shows as its time until it settles.
    package private(set) var sentAt: Date?
    /// The list's order when the note began, held until the row settles so the sent note's
    /// activity can't move its row mid-beat.
    package private(set) var order: [String]?
    @ObservationIgnored private var listened: TimeInterval = 0
    @ObservationIgnored private var store: ChannelStore?
    @ObservationIgnored private weak var catalog: ChannelCatalogStore?
    /// The note's one attempt in the channel's outbox, which Send Again repeats under its UUID.
    @ObservationIgnored private var attempt: (id: String, content: String)?
    @ObservationIgnored private let checks: CardChecks
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private let draft: @MainActor (ChannelStore) -> ComposerDraft
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private let animate: @MainActor (CardMotion, () -> Void) -> Void
    @ObservationIgnored private let pause: @MainActor (Duration) async -> Void

    package static let sampleCount = 64

    /// - Parameters:
    ///   - checks: The list's done checks, which the row wears once its note sends.
    ///   - draft: The channel's composer draft, which keeps the words of a note left mid-way.
    ///   - announce: Speaks a VoiceOver announcement.
    ///   - animate: Applies one beat's change in that beat's motion.
    ///   - pause: Waits while a beat's motion plays, before the next beat.
    package init(system: DictationSystem, checks: CardChecks,
                 draft: @escaping @MainActor (ChannelStore) -> ComposerDraft,
                 announce: @escaping @MainActor (String) -> Void,
                 animate: @escaping @MainActor (CardMotion, () -> Void) -> Void = { $1() },
                 pause: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        dictation = ComposerDictation(system: system)
        self.checks = checks
        self.draft = draft
        self.announce = announce
        self.animate = animate
        self.pause = pause
        dictation.target = self
    }

    /// Talk shows only where dictation supports the person's language.
    package var isAvailable: Bool { dictation.availability != .checking && dictation.availability != .unsupported }

    /// True while the recorder holds the list, which dims every other row.
    package var isOpen: Bool {
        switch phase {
        case .recording, .sending, .failed: true
        case .sent, .landed, .cancelled, nil: false
        }
    }

    /// True while the held row wears the done check, from the note's Send until the check settles.
    package var isChecked: Bool {
        guard phase == .sent || phase == .landed, let channelID else { return false }
        return checks[channelID] == .sent
    }

    /// What the row's time slot shows in place of the time, until the row's check settles.
    package var timeSlot: TimeSlot? {
        switch phase {
        case .recording, .sending: isOffline ? .offline : .counter
        case .failed(let failure): .failed(failure)
        case .sent, .landed: isChecked ? .noteTime : nil
        case .cancelled, nil: nil
        }
    }

    /// The rows whose bottom line the open card covers: the held row, the row above it, whose line
    /// is the held row's top, and the row below it, so the card never crosses a line. The lines
    /// return in the shrink's own transaction, on Send and on Cancel.
    package var hiddenLines: Set<String> {
        guard isOpen, let held = channelID else { return [] }
        guard let order, let index = order.firstIndex(of: held) else { return [held] }
        return Set(order[max(index - 1, 0)...min(index + 1, order.count - 1)])
    }

    /// The chevron and attention mark stay hidden until the card has landed.
    package var hidesTrailingColumn: Bool {
        switch phase {
        case .recording, .sending, .failed, .sent: true
        case .landed, .cancelled, nil: false
        }
    }

    /// The channel row's accessibility value while the recorder is on it.
    package func rowValue(details: String) -> String {
        switch phase {
        case .recording: canResume ? "Paused" : isOffline ? "Recording, offline" : "Recording"
        case .sending: "Sending"
        case .failed(let failure): failure.label
        case .sent, .landed: isChecked ? "Sent to Lead. " + details : details
        case .cancelled, nil: details
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

    package var canSend: Bool {
        switch phase {
        case .recording:
            dictation.phase != .finishing && !isOffline
                && !finalizedWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .failed: !isOffline
        default: false
        }
    }

    /// The mic offers Resume once listening stops, after silence, a failure or with access off.
    package var canResume: Bool { phase == .recording && dictation.phase == .idle }

    package func elapsed(at date: Date) -> TimeInterval {
        listened + (listeningSince.map { max(date.timeIntervalSince($0), 0) } ?? 0)
    }

    /// Channels in the order they had when the note began, with any new ones after them.
    package func ordered(_ channels: [Channel]) -> [Channel] {
        guard let order else { return channels }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return channels.enumerated()
            .sorted { (rank[$0.element.id] ?? order.count + $0.offset, $0.offset)
                < (rank[$1.element.id] ?? order.count + $1.offset, $1.offset) }
            .map(\.element)
    }

    /// Checks the language only, so Talk can show without touching the microphone.
    package func activate() { dictation.activate() }

    package func deactivate() {
        leave()
        dictation.deactivate()
    }

    /// Opens the recorder on the channel's row and starts listening.
    package func start(_ store: ChannelStore, name: String, contextualNames: [String] = [],
                       catalog: ChannelCatalogStore? = nil, order: [String] = []) {
        guard isAvailable, !isOpen else { return }
        // Talking again on a row that still wears the check keeps its card, so the check swaps
        // straight to the mic.
        if phase != nil { close(keepingCell: channelID == store.id) }
        self.store = store
        self.catalog = catalog
        self.order = order
        attempt = nil
        sentAt = nil
        committed = ""
        transcript = .init()
        levels = Array(repeating: 0, count: Self.sampleCount)
        listened = 0
        listeningSince = nil
        dictation.contextualStrings = ["Lead"] + contextualNames
        animate(.open) {
            channelID = store.id
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

    /// Sends the finalized words as a new message to the Lead, or repeats a failed attempt.
    package func send() async {
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
        postingSince = .now
        let sentAt: Date?
        do { sentAt = try await store.postInBackground(id: attempt.id, content: attempt.content).sentAt }
        catch { sentAt = nil }
        guard self.store === store, self.attempt?.id == attempt.id else { return }
        postingSince = nil
        guard let sentAt else {
            let failure = store.failedPhase(ofSend: attempt.id)
            phase = .failed(failure)
            return announce(failure.label)
        }
        self.sentAt = sentAt
        animate(.sent) {
            phase = .sent
            checks.sent(store.id)
        }
        announce("Sent to Lead in \(channelName)")
        land(store.id)
    }

    /// Lands the card as its shrink ends, then ends the note once its row's check has settled.
    private func land(_ channelID: String) {
        closing?.cancel()
        closing = Task { [weak self] in
            await self?.pause(.seconds(0.35))
            guard let self, !Task.isCancelled, phase == .sent else { return }
            animate(.settle) { phase = .landed }
            for await check in Observations({ [checks] in checks[channelID] }) where check == nil { break }
            guard !Task.isCancelled, phase == .landed else { return }
            close()
        }
    }

    /// Discards a note nothing has sent, and closes the row with the open spring in reverse. After a
    /// failure, the note stays in the channel's outbox, where the conversation offers Send Again like
    /// any failed send.
    package func cancel() {
        switch phase {
        case .recording, .failed:
            following?.cancel()
            sampling?.cancel()
            listeningSince = nil
            dictation.leaveDraft()
            animate(.open) { phase = .cancelled }
            closing?.cancel()
            closing = Task { [weak self] in
                await self?.pause(.seconds(0.45))
                guard let self, !Task.isCancelled, phase == .cancelled else { return }
                close()
            }
        case .sending, .sent, .landed, .cancelled, nil:
            break
        }
    }

    /// Ends the note when something takes the person away from the list. Words still being
    /// recorded become the channel's draft, after any draft already there.
    package func leave() {
        guard phase != nil else { return }
        if phase == .recording {
            dictation.commitNow()
            let words = finalizedWords.trimmingCharacters(in: .whitespacesAndNewlines)
            if let store, !words.isEmpty {
                let draft = draft(store)
                draft.text = ComposerDraft.joined(draft.text, words)
            }
        }
        close()
    }

    private func close(keepingCell: Bool = false) {
        // A sent note's check leaves with its card, and talking again swaps it straight to the mic.
        if phase == .sent || phase == .landed, let channelID { checks.clear(channelID) }
        phase = nil
        channelID = nil
        if !keepingCell {
            cell = nil
            isGrown = false
        }
        order = nil
        following?.cancel()
        sampling?.cancel()
        closing?.cancel()
        dictation.leaveDraft()
        store = nil
        attempt = nil
        postingSince = nil
        sentAt = nil
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
