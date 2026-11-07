import ChannelKit
import Foundation
import Observation

/// The Needs You cards in the phone's channel list: a waiting channel's row shows its question, one
/// card opens at a time, and a choice or a typed reply answers it without opening the channel. It
/// holds the cards' rules, and the app draws them and supplies their motion. See Needs You in the
/// list in docs/spec.md.
@MainActor @Observable
package final class NeedsYouCards {
    /// One waiting request, by its channel and its message's sequence.
    package struct Request: Hashable, Sendable {
        package var channelID: String
        package var sequence: Int

        package init(channelID: String, sequence: Int) {
            self.channelID = channelID
            self.sequence = sequence
        }
    }

    package enum Phase: Equatable {
        /// The card lifted above the list, with the field for a typed reply.
        case composing
        case sending
        /// The reply stays in the channel's outbox under its UUID, so Send Again can't post it twice.
        case failed(ChannelSendPhase)
    }

    /// The done check a row wears once its reply sends here, as the talk card's row does.
    package enum Check: Equatable, Sendable {
        /// The card has shrunk back into its row, which wears the check.
        case sent
        /// The check swaps back to the channel's mark.
        case settling
    }

    /// The card's beats, which the app animates with the talk card's motion.
    package enum Motion { case open, lift, sent, settle }

    /// The request being answered, as it was when the answer began, since the catalog drops it
    /// once the server has the answer.
    package private(set) var replying: ChannelWaitingRequests.Entry?
    package private(set) var phase: Phase?
    /// True while a typed reply holds the list, with its card lifted and every other row dimmed.
    package private(set) var isLifted = false
    /// The typed reply, or the chosen reply once it's sending.
    package var words = ""
    /// True once a send has gone 300 ms without confirming.
    package private(set) var showsProgress = false
    /// True once the reply has failed, so its card keeps the failure's place while Send Again retries.
    package private(set) var hasFailed = false
    /// The rows wearing the done check, by channel.
    package private(set) var checks: [String: Check] = [:]
    /// The card the person opened, which stays open while its request waits.
    package private(set) var chosen: Request?
    /// Requests answered here, which never reopen while the catalog catches up.
    package private(set) var answered: Set<Request> = []
    @ObservationIgnored private var store: ChannelStore?
    @ObservationIgnored private var handle: String?
    @ObservationIgnored private var attempt: (id: String, content: String)?
    @ObservationIgnored private var settles: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let draft: @MainActor (ChannelStore) -> ComposerDraft
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private let animate: @MainActor (Motion, () -> Void) -> Void
    @ObservationIgnored private let pause: @MainActor (Duration) async -> Void

    /// - Parameters:
    ///   - draft: The channel's composer draft, which keeps a typed reply left mid-way.
    ///   - announce: Speaks a VoiceOver announcement.
    ///   - animate: Applies one beat's change in that beat's motion.
    ///   - pause: Waits while a beat's motion plays, before the next beat.
    package init(draft: @escaping @MainActor (ChannelStore) -> ComposerDraft,
                 announce: @escaping @MainActor (String) -> Void,
                 animate: @escaping @MainActor (Motion, () -> Void) -> Void = { $1() },
                 pause: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.draft = draft
        self.announce = announce
        self.animate = animate
        self.pause = pause
    }

    /// The open card among the waiting requests, newest first: the one being answered, otherwise
    /// the one the person opened while it waits, otherwise the newest.
    package func open(in waiting: [ChannelWaitingRequests.Entry]) -> ChannelWaitingRequests.Entry? {
        if let replying { return waiting.first { $0.card == replying.card } ?? replying }
        let unanswered = waiting.filter { !answered.contains($0.card) }
        return unanswered.first { $0.card == chosen } ?? unanswered.first
    }

    /// True when the open card changed from `previous` to `card` because of the person: a tap on
    /// its row, or their answer to the card before it. Only those scroll the list, so a request
    /// arriving never moves it under someone reading.
    package func reveals(_ card: Request?, after previous: Request?) -> Bool {
        guard let card else { return false }
        return card == chosen || previous.map(answered.contains) == true
    }

    /// True when the request still needs an answer here, so its row shows its question.
    package func isWaiting(_ entry: ChannelWaitingRequests.Entry) -> Bool {
        !answered.contains(entry.card)
    }

    /// Opens a compact row's card, closing the others. A failed reply's card closes too, and its
    /// reply waits in the channel's outbox.
    package func choose(_ request: Request) {
        guard !isLifted, phase != .sending, chosen != request || replying != nil else { return }
        animate(.open) {
            if case .failed = phase { close() }
            chosen = request
        }
    }

    /// Sends a choice at once as written, through the channel's outbox with a new UUID.
    package func send(_ choice: String, to entry: ChannelWaitingRequests.Entry, on store: ChannelStore) async {
        guard replying == nil else { return }
        begin(entry, on: store, handle: nil)
        words = choice
        attempt = (UUID().uuidString, choice)
        await deliver()
    }

    /// Lifts the card above the list with an empty field for a typed reply, which goes to the
    /// requester by leading with their handle.
    package func reply(to entry: ChannelWaitingRequests.Entry, on store: ChannelStore) {
        guard replying == nil else { return }
        animate(.lift) {
            begin(entry, on: store, handle: entry.request?.requester?.handle)
            words = ""
            isLifted = true
            phase = .composing
        }
    }

    /// True when the typed reply has words to send.
    package var canSend: Bool {
        phase == .composing && ChannelNotification.Reply(words, to: handle) != nil
    }

    /// Sends the typed reply, or repeats a failed attempt under its UUID.
    package func send() async {
        if case .failed = phase { return await deliver() }
        guard canSend, let content = ChannelNotification.Reply(words, to: handle)?.content else { return }
        attempt = (UUID().uuidString, content)
        await deliver()
    }

    private func begin(_ entry: ChannelWaitingRequests.Entry, on store: ChannelStore, handle: String?) {
        replying = entry
        chosen = entry.card
        self.store = store
        self.handle = handle
    }

    private func deliver() async {
        guard let attempt, let store, let entry = replying else { return }
        let request = entry.card
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
            _ = try await store.postInBackground(id: attempt.id, content: attempt.content)
            guard replying?.card == request, self.attempt?.id == attempt.id else { return }
            // The card shrinks straight back into its row, which wears the check, as the next opens.
            animate(.sent) {
                answered.insert(request)
                checks[entry.channel.id] = .sent
                close()
            }
            announce("Reply sent in \(entry.channel.name)")
            settle(entry.channel.id)
        } catch {
            guard replying?.card == request, self.attempt?.id == attempt.id else { return }
            let failure: ChannelSendPhase =
                store.sendAttempts.first { $0.id == attempt.id }?.phase == .deliveryNotConfirmed
                ? .deliveryNotConfirmed : .notSent
            phase = .failed(failure)
            hasFailed = true
            announce(failure.label)
        }
    }

    /// Holds the check as long as the talk card does, through the shrink and two seconds more, then
    /// swaps it back to the channel's mark. Each row settles on its own, so answering the next card
    /// leaves this one's check in place.
    private func settle(_ channelID: String) {
        settles[channelID]?.cancel()
        settles[channelID] = Task { [weak self] in
            await self?.pause(.seconds(2.35))
            guard let self, !Task.isCancelled else { return }
            animate(.settle) { checks[channelID] = .settling }
            await pause(.seconds(0.45))
            guard !Task.isCancelled else { return }
            checks[channelID] = nil
            settles[channelID] = nil
        }
    }

    /// Lowers a typed reply back into its row and discards its words. After a failure, the reply
    /// stays in the channel's outbox, where the conversation offers Send Again like any failed send.
    package func cancel() {
        switch phase {
        case .composing, .failed: animate(isLifted ? .lift : .open) { close() }
        case .sending, nil: break
        }
    }

    /// Ends the reply when something takes the person away from the list. A typed reply's words
    /// become the channel's draft, after any draft already there.
    package func leave() {
        if phase == .composing, let store {
            let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty {
                let draft = draft(store)
                draft.text = ComposerDraft.joined(draft.text, words)
            }
        }
        if phase != .sending { close() }
    }

    private func close() {
        replying = nil
        phase = nil
        isLifted = false
        hasFailed = false
        words = ""
        showsProgress = false
        store = nil
        handle = nil
        attempt = nil
    }
}

extension ChannelWaitingRequests.Entry {
    /// The request's identity, which outlives the entry's channel details.
    package var card: NeedsYouCards.Request { .init(channelID: channel.id, sequence: sequence) }
}
