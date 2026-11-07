import ChannelKit
import Foundation
import Observation

/// The Needs You cards in the phone's channel list: a waiting channel's row shows its question, one
/// card opens at a time, and a choice or a typed reply answers it without opening the channel. It
/// holds the cards' rules, and the app draws them and supplies their motion. See Needs You in the
/// list in docs/spec.md.
@MainActor @Observable
package final class NeedsYouCards {
    package enum Phase: Equatable {
        /// The card lifted above the list, with the field for a typed reply.
        case composing
        case sending
        /// The reply stays in the channel's outbox under its UUID, so Send Again can't post it twice.
        case failed(ChannelSendPhase)
    }

    /// What a waiting channel's row shows.
    package enum Row: Equatable {
        /// The open card, with its whole question, choices and Reply.
        case card(ChannelWaitingRequests.Entry)
        /// A waiting row, with its question in one line.
        case question(ChannelWaitingRequests.Entry)
    }

    /// An answer from the open card, from its start until it's sent, cancelled or left.
    private struct Answer {
        let entry: ChannelWaitingRequests.Entry
        let isLifted: Bool
        let store: ChannelStore
        /// Leads a typed reply, so it goes to the requester.
        let handle: String?
        var phase: Phase
        var hasFailed = false
        /// The reply's one attempt in the channel's outbox, which Send Again repeats under its UUID.
        var attempt: (id: String, content: String)?
        var postingSince: ContinuousClock.Instant?
    }

    private var answer: Answer?
    /// The typed reply, or the chosen reply once it's sending.
    package var words = ""
    /// The card the person opened, which stays open while its request waits.
    package private(set) var opened: ChannelWaitingRequests.Entry.ID?
    /// Requests answered here, which never reopen while the catalog catches up.
    package private(set) var answered: Set<ChannelWaitingRequests.Entry.ID> = []
    @ObservationIgnored private let checks: CardChecks
    @ObservationIgnored private let draft: @MainActor (ChannelStore) -> ComposerDraft
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private let animate: @MainActor (CardMotion, () -> Void) -> Void
    @ObservationIgnored private let pause: @MainActor (Duration) async -> Void

    /// - Parameters:
    ///   - checks: The list's done checks, which a row wears once its reply sends.
    ///   - draft: The channel's composer draft, which keeps a typed reply left mid-way.
    ///   - announce: Speaks a VoiceOver announcement.
    ///   - animate: Applies one beat's change in that beat's motion.
    ///   - pause: Waits while a beat's motion plays, before the next beat.
    package init(checks: CardChecks, draft: @escaping @MainActor (ChannelStore) -> ComposerDraft,
                 announce: @escaping @MainActor (String) -> Void,
                 animate: @escaping @MainActor (CardMotion, () -> Void) -> Void = { $1() },
                 pause: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.checks = checks
        self.draft = draft
        self.announce = announce
        self.animate = animate
        self.pause = pause
    }

    /// The request being answered, as it was when the answer began, since the catalog drops it once
    /// the server has the answer.
    package var replying: ChannelWaitingRequests.Entry? { answer?.entry }
    package var phase: Phase? { answer?.phase }
    /// True while a typed reply holds the list, with its card lifted and every other row dimmed.
    package var isLifted: Bool { answer?.isLifted == true }
    /// True once the reply has failed, so its card keeps the failure's place while Send Again retries.
    package var hasFailed: Bool { answer?.hasFailed == true }
    /// When the reply's attempt began posting, which Send's progress waits 300 ms from.
    package var postingSince: ContinuousClock.Instant? { answer?.postingSince }

    /// The open card among the waiting requests, newest first: the one being answered, otherwise
    /// the one the person opened while it waits, otherwise the newest.
    package func open(in waiting: [ChannelWaitingRequests.Entry]) -> ChannelWaitingRequests.Entry? {
        if let replying { return waiting.first { $0.id == replying.id } ?? replying }
        let unanswered = waiting.filter { !answered.contains($0.id) }
        return unanswered.first { $0.id == opened } ?? unanswered.first
    }

    /// True when the open card changed from `previous` to `card` because of the person: a tap on
    /// its row, or their answer to the card before it. Only those scroll the list, so a request
    /// arriving never moves it under someone reading.
    package func reveals(_ card: ChannelWaitingRequests.Entry.ID?,
                         after previous: ChannelWaitingRequests.Entry.ID?) -> Bool {
        guard let card else { return false }
        return card == opened || previous.map(answered.contains) == true
    }

    /// True when the request still needs an answer here, so its row shows its question.
    package func isWaiting(_ entry: ChannelWaitingRequests.Entry) -> Bool {
        !answered.contains(entry.id)
    }

    /// What each waiting row shows, by channel. A request answered here leaves an ordinary row
    /// while the catalog catches up.
    package func rows(in waiting: [ChannelWaitingRequests.Entry]) -> [String: Row] {
        var rows: [String: Row] = [:]
        for entry in waiting where isWaiting(entry) { rows[entry.channel.id] = .question(entry) }
        if let open = open(in: waiting) { rows[open.channel.id] = .card(open) }
        return rows
    }

    /// The rows whose bottom line the open card covers: its own, and the one above, whose line is the
    /// card's top. `order` is the list's channels, top to bottom.
    package func hiddenLines(in waiting: [ChannelWaitingRequests.Entry], order: [String]) -> Set<String> {
        guard let open = open(in: waiting)?.channel.id, let index = order.firstIndex(of: open) else { return [] }
        return Set([open] + order[..<index].suffix(1))
    }

    /// Opens a compact row's card, closing the others. A failed reply's card closes too, and its
    /// reply waits in the channel's outbox.
    package func open(_ request: ChannelWaitingRequests.Entry.ID) {
        guard !isLifted, phase != .sending, opened != request || replying != nil else { return }
        animate(.open) {
            if case .failed = phase { close() }
            opened = request
        }
    }

    /// Sends a choice at once as written, through the channel's outbox with a new UUID.
    package func send(_ choice: String, to entry: ChannelWaitingRequests.Entry, on store: ChannelStore) async {
        guard answer == nil else { return }
        opened = entry.id
        answer = Answer(entry: entry, isLifted: false, store: store, handle: nil, phase: .sending,
                        attempt: (UUID().uuidString, choice))
        words = choice
        await deliver()
    }

    /// Lifts the card above the list with an empty field for a typed reply, which goes to the
    /// requester by leading with their handle.
    package func reply(to entry: ChannelWaitingRequests.Entry, on store: ChannelStore) {
        guard answer == nil else { return }
        animate(.open) {
            opened = entry.id
            answer = Answer(entry: entry, isLifted: true, store: store, handle: entry.request?.requester?.handle,
                            phase: .composing)
            words = ""
        }
    }

    /// True when the typed reply has words to send.
    package var canSend: Bool {
        phase == .composing && ChannelNotification.Reply(words, to: answer?.handle) != nil
    }

    /// Sends the typed reply, or repeats a failed attempt under its UUID.
    package func send() async {
        if case .failed = phase { return await deliver() }
        guard canSend, let content = ChannelNotification.Reply(words, to: answer?.handle)?.content else { return }
        answer?.attempt = (UUID().uuidString, content)
        await deliver()
    }

    private func deliver() async {
        guard let answer, let attempt = answer.attempt else { return }
        let entry = answer.entry
        self.answer?.phase = .sending
        self.answer?.postingSince = .now
        let posted: Bool
        do {
            try await answer.store.postInBackground(id: attempt.id, content: attempt.content)
            posted = true
        } catch { posted = false }
        guard self.answer?.attempt?.id == attempt.id else { return }
        self.answer?.postingSince = nil
        guard posted else {
            let failure = answer.store.failedPhase(ofSend: attempt.id)
            self.answer?.phase = .failed(failure)
            self.answer?.hasFailed = true
            return announce(failure.label)
        }
        // The card shrinks straight back into its row, which wears the check, as the next opens.
        // Each row's check settles on its own, so answering the next card leaves this one's in place.
        animate(.sent) {
            answered.insert(entry.id)
            checks.sent(entry.channel.id)
            close()
        }
        announce("Reply sent in \(entry.channel.name)")
    }

    /// Lowers a typed reply back into its row and discards its words. After a failure, the reply
    /// stays in the channel's outbox, where the conversation offers Send Again like any failed send.
    package func cancel() {
        switch phase {
        case .composing, .failed: animate(.open) { close() }
        case .sending, nil: break
        }
    }

    /// Ends the reply when something takes the person away from the list. A typed reply's words
    /// become the channel's draft, after any draft already there.
    package func leave() {
        if phase == .composing, let store = answer?.store {
            let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty {
                let draft = draft(store)
                draft.text = ComposerDraft.joined(draft.text, words)
            }
        }
        if phase != .sending { close() }
    }

    private func close() {
        answer = nil
        words = ""
    }
}
