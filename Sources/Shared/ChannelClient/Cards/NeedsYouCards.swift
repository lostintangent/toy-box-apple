import ChannelKit
import Foundation
import Observation

/// The Needs You cards in the phone's channel list: a waiting channel's row shows its question, one
/// card opens at a time, and a choice or a typed reply answers it without opening the channel. A
/// reply goes to the outbox, so the card closes with its check at once, and a reply that ends Not
/// sent brings its request back as a waiting row. It holds the cards' rules, and the app draws them
/// and supplies their motion. See Needs You in the list in docs/spec.md.
@MainActor @Observable
package final class NeedsYouCards {
    package enum Phase: Equatable {
        /// The card lifted above the list, with the field for a typed reply.
        case composing
        /// The outbox is saving the reply, which holds the card for that moment.
        case sending
    }

    /// What a waiting channel's row shows.
    package enum Row: Equatable {
        /// The open card, with its whole question, choices and Reply.
        case card(ChannelCatalogStore.WaitingRequest)
        /// A waiting row, with its question in one line.
        case question(ChannelCatalogStore.WaitingRequest)
    }

    /// An answer from the open card, from its start until it's sent, cancelled or left.
    private struct Answer {
        let entry: ChannelCatalogStore.WaitingRequest
        let isLifted: Bool
        let store: ChannelStore
        /// Leads a typed reply, so it goes to the requester.
        let handle: String?
        var phase: Phase
    }

    private var answer: Answer?
    /// The typed reply, kept while its card lands, or the chosen reply once it's sending.
    package var words = ""
    /// The card the person opened, which stays open while its request waits.
    package private(set) var opened: ChannelCatalogStore.WaitingRequest.ID?
    /// The request answered here last, so the card that opens after it scrolls into view.
    private var answered: ChannelCatalogStore.WaitingRequest.ID?
    /// A sent typed reply's card while it shrinks from above the list back into its row.
    package private(set) var landing: ChannelCatalogStore.WaitingRequest?
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

    /// The request being answered, as it was when the answer began, since the waiting requests drop
    /// it once the outbox has the answer.
    package var replying: ChannelCatalogStore.WaitingRequest? { answer?.entry }
    package var phase: Phase? { answer?.phase }
    /// True while a typed reply holds the list, with its card lifted and every other row dimmed.
    package var isLifted: Bool { answer?.isLifted == true }

    /// The open card among every server's waiting requests, newest first: the one being answered, otherwise
    /// the one the person opened while it waits, otherwise the newest. A request opens only once its
    /// words are known.
    package func open(in waiting: [ChannelCatalogStore.WaitingRequest]) -> ChannelCatalogStore.WaitingRequest? {
        if let replying { return waiting.first { $0.id == replying.id } ?? replying }
        let known = waiting.filter { $0.request != nil }
        return known.first { $0.id == opened } ?? known.first
    }

    /// True when the open card changed from `previous` to `card` because of the person: a tap on
    /// its row, or their answer to the card before it. Only those scroll the list, so a request
    /// arriving never moves it under someone reading.
    package func reveals(_ card: ChannelCatalogStore.WaitingRequest.ID?,
                         after previous: ChannelCatalogStore.WaitingRequest.ID?) -> Bool {
        guard let card else { return false }
        return card == opened || (previous != nil && previous == answered)
    }

    /// What each waiting row shows, by channel on its server. A request whose words aren't known yet
    /// leaves its channel an ordinary row.
    package func rows(in waiting: [ChannelCatalogStore.WaitingRequest]) -> [ChannelTarget: Row] {
        var rows: [ChannelTarget: Row] = [:]
        for entry in waiting where entry.request != nil {
            if let target = entry.target { rows[target] = .question(entry) }
        }
        if let open = open(in: waiting), let target = open.target { rows[target] = .card(open) }
        return rows
    }

    /// The rows whose bottom line the open card covers: its own, and the one above, whose line is the
    /// card's top. `order` is the list's channels, top to bottom.
    package func hiddenLines(in waiting: [ChannelCatalogStore.WaitingRequest], order: [ChannelTarget]) -> Set<ChannelTarget> {
        guard let open = open(in: waiting)?.target, let index = order.firstIndex(of: open) else { return [] }
        return Set([open] + order[..<index].suffix(1))
    }

    /// Opens a compact row's card, closing the others.
    package func open(_ request: ChannelCatalogStore.WaitingRequest.ID) {
        guard answer == nil, opened != request else { return }
        animate(.open) { opened = request }
    }

    /// Sends a choice at once as written.
    package func send(_ choice: String, to entry: ChannelCatalogStore.WaitingRequest, on store: ChannelStore) async {
        guard answer == nil, store.outbox != nil else { return }
        opened = entry.id
        answer = Answer(entry: entry, isLifted: false, store: store, handle: nil, phase: .sending)
        words = choice
        await deliver(choice)
    }

    /// Lifts the card above the list with an empty field for a typed reply, which goes to the
    /// requester by leading with their handle.
    package func reply(to entry: ChannelCatalogStore.WaitingRequest, on store: ChannelStore) {
        guard answer == nil else { return }
        animate(.open) {
            landing = nil
            opened = entry.id
            answer = Answer(entry: entry, isLifted: true, store: store, handle: entry.request?.requester?.handle,
                            phase: .composing)
            words = ""
        }
    }

    /// True when the typed reply has words to send.
    package var canSend: Bool {
        phase == .composing && answer?.store.outbox != nil
            && ChannelNotification.Reply(words, to: answer?.handle) != nil
    }

    /// Sends the typed reply.
    package func send() async {
        guard canSend, let content = ChannelNotification.Reply(words, to: answer?.handle)?.content else { return }
        await deliver(content)
    }

    private func deliver(_ content: String) async {
        guard let answer, let outbox = answer.store.outbox else { return }
        let entry = answer.entry
        self.answer?.phase = .sending
        // The request stops waiting as the outbox takes the reply, and the card holds until it's saved.
        await outbox.send(content, to: entry.channel.id, on: answer.store.api.baseURL, answering: entry.sequence)
        guard self.answer?.entry.id == entry.id, self.answer?.phase == .sending else { return }
        // The card shrinks straight back into its row, which wears the check, as the next opens.
        // Each row's check settles on its own, so answering the next card leaves this one's in place.
        // A typed reply's words fade with its card rather than blanking as it lands.
        animate(.sent) {
            answered = entry.id
            // The card the person opened ends with its answer, so if the reply ends Not sent, its
            // request comes back without opening itself or moving the list.
            opened = nil
            if let target = entry.target { checks.sent(target) }
            if answer.isLifted {
                landing = entry
                self.answer = nil
            } else {
                close()
            }
        }
        announce("Reply sent in \(entry.channel.name)")
        guard landing?.id == entry.id else { return }
        await pause(.seconds(0.35))
        guard landing?.id == entry.id else { return }
        landing = nil
        if self.answer == nil { words = "" }
    }

    /// Lowers a typed reply back into its row and discards its words.
    package func cancel() {
        guard phase == .composing else { return }
        animate(.open) { close() }
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
