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
        /// The card shows Sent with the reply's words, before it shrinks back into its row.
        case sent
    }

    /// The card's beats, which the app animates with the spec's springs.
    package enum Motion { case open, lift, sent, shrink }

    /// The request being answered, as it was when the answer began, since the catalog drops it
    /// once the server has the answer.
    package private(set) var replying: ChannelWaitingRequests.Entry?
    package private(set) var phase: Phase?
    /// True while a typed reply holds the list, with its card lifted and every other row dimmed.
    package private(set) var isLifted = false
    /// True while the Sent card shrinks back into its row, still showing Sent, as the next opens.
    package private(set) var isShrinking = false
    /// The typed reply, or the chosen reply once it's sending.
    package var words = ""
    /// True once a send has gone 300 ms without confirming.
    package private(set) var showsProgress = false
    /// The card the person opened, which stays open while its request waits.
    package private(set) var chosen: Request?
    /// Requests answered here, which never reopen while the catalog catches up.
    package private(set) var answered: Set<Request> = []
    @ObservationIgnored private var store: ChannelStore?
    @ObservationIgnored private var handle: String?
    @ObservationIgnored private var attempt: (id: String, content: String)?
    @ObservationIgnored private var settling: Task<Void, Never>?
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

    /// The open card among the waiting requests, newest first: the one being answered until it
    /// shrinks back, otherwise the one the person opened while it waits, otherwise the newest.
    package func open(in waiting: [ChannelWaitingRequests.Entry]) -> ChannelWaitingRequests.Entry? {
        if let replying, !isShrinking { return waiting.first { $0.card == replying.card } ?? replying }
        let unanswered = waiting.filter { !answered.contains($0.card) }
        return unanswered.first { $0.card == chosen } ?? unanswered.first
    }

    /// True when the request still needs an answer here, so its row shows its question.
    package func isWaiting(_ entry: ChannelWaitingRequests.Entry) -> Bool {
        !answered.contains(entry.card)
    }

    /// Opens a compact row's card, closing the others. A failed reply's card closes too, and its
    /// reply waits in the channel's outbox.
    package func choose(_ request: Request) {
        guard !isLifted, phase != .sending, phase != .sent, chosen != request || replying != nil else { return }
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
        settling?.cancel()
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
            animate(.sent) {
                answered.insert(request)
                isLifted = false
                phase = .sent
            }
            announce("Reply sent in \(entry.channel.name)")
            settling = Task { [weak self] in
                await self?.pause(.seconds(1.6))
                guard let self, !Task.isCancelled, phase == .sent, replying?.card == request else { return }
                animate(.shrink) { isShrinking = true }
                await pause(.seconds(0.5))
                if !Task.isCancelled { close() }
            }
        } catch {
            guard replying?.card == request, self.attempt?.id == attempt.id else { return }
            let failure: ChannelSendPhase =
                store.sendAttempts.first { $0.id == attempt.id }?.phase == .deliveryNotConfirmed
                ? .deliveryNotConfirmed : .notSent
            phase = .failed(failure)
            announce(failure.label)
        }
    }

    /// Lowers a typed reply back into its row and discards its words. After a failure, the reply
    /// stays in the channel's outbox, where the conversation offers Send Again like any failed send.
    package func cancel() {
        switch phase {
        case .composing, .failed: animate(isLifted ? .lift : .open) { close() }
        case .sending, .sent, nil: break
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
        settling?.cancel()
        replying = nil
        phase = nil
        isLifted = false
        isShrinking = false
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
