import ChannelClient
import ChannelKit
import Foundation
import Observation

/// Presentation state only. Delivery, deduplication and retry classification stay in ChannelStore.
@MainActor @Observable
final class AuxiliaryComposerSession {
    struct Confirmation: Equatable {
        let id: String
        let sequence: Int?
        let opensChannel: Bool
    }

    /// The attempt this session sent, and the draft revision it was sent from.
    private struct Submission {
        let id: String
        let revision: UUID
    }

    private let composer: ChannelComposerSession
    let requestSequence: Int?
    private(set) var confirmation: Confirmation?
    private(set) var error: String?
    private(set) var editedUnconfirmedMessage = false
    private var submission: Submission?
    private var opensChannel = false
    private var requestInvalidated = false
    private var replacementRequestSequence: Int?
    @ObservationIgnored var prepareForExternalEdit: (@MainActor () -> Void)?
    @ObservationIgnored private var observation = UUID()
    @ObservationIgnored private var presentedConfirmationID: String?

    var store: ChannelStore { composer.store }
    var draft: ComposerDraft { composer.draft }
    var isSubmitting: Bool { composer.isSubmitting }

    init(store: ChannelStore, scope: ComposerDraft.Scope, requester: ChannelAgent? = nil,
         draft: ComposerDraft? = nil) {
        let draft = draft ?? .shared(serverURL: store.api.baseURL, channelID: store.id, scope: scope)
        composer = ChannelComposerSession(store: store, draft: draft, keepsDraftUntilConfirmed: true)
        if case .inboxReply(let sequence) = scope { requestSequence = sequence }
        else { requestSequence = nil }
        if let requester { seedRequesterIfNew(requester) }
        if let id = draft.sendAttemptID {
            submission = Submission(id: id, revision: draft.revision)
            observeDelivery()
        }
    }

    var attempt: ChannelSendAttempt? {
        guard let id = submission?.id, draft.sendAttemptID == id else { return nil }
        return store.sendAttempts.first { $0.id == id }
    }

    var requestChanged: Bool {
        requestSequence.map { requestInvalidated || (store.isLoaded && store.requestSequence != $0) } ?? false
    }

    func seedRequesterIfNew(_ requester: ChannelAgent) {
        guard draft.isNew, !draft.hasContent, requestSequence != nil else { return }
        draft.text = "@\(agentHandleFromName(requester.name)) "
    }

    func invalidateRequest(replacementSequence: Int? = nil) {
        requestInvalidated = true
        replacementRequestSequence = replacementSequence
    }

    var requestChangeNotice: String {
        if replacementRequestSequence != nil
            || (store.requestSequence != nil && store.requestSequence != requestSequence) {
            return "A newer request is waiting."
        }
        return "This request was answered elsewhere."
    }

    var isReadOnly: Bool { submission != nil && draft.sendAttemptID == submission?.id }

    var canSend: Bool { composer.canSend(isBlocked: requestChanged || confirmation != nil) }

    var isUnconfirmed: Bool {
        isReadOnly && !isSubmitting && confirmation == nil && attempt?.phase != .sending
    }

    var deliveryNotice: String? {
        guard isUnconfirmed else { return nil }
        if attempt?.phase == .notSent { return "Not sent. \(attempt?.error ?? error ?? "Try sending again.")" }
        if let error, attempt == nil { return error }
        return "Delivery not confirmed. It may have arrived."
    }

    func send(opensChannel: Bool = false) async {
        guard canSend else {
            error = requestChanged ? "This request changed. Open the channel before replying."
                : "This message cannot be sent yet. Check the connection and attachments."
            return
        }
        let id = draft.sendAttemptID ?? UUID().uuidString
        if submission?.id != id { submission = Submission(id: id, revision: draft.revision) }
        draft.associateSend(id: id)
        self.opensChannel = opensChannel
        error = nil
        observeDelivery()
        guard let result = await composer.submit() else {
            if confirmation == nil, submission?.id == id {
                error = attempt == nil ? composer.error.map { "Not sent. \($0)" } : nil
            }
            return
        }
        switch result {
        case .committed(let message): confirm(id: id, sequence: message.sequence)
        case .alreadyAccepted(let acceptedID): confirm(id: acceptedID, sequence: nil)
        }
    }

    func edit() {
        guard !isSubmitting, attempt?.phase != .sending else { return }
        editedUnconfirmedMessage = attempt?.phase != .notSent
        draft.editAsNewMessage()
        submission = nil
        confirmation = nil
        error = nil
        observation = UUID()
    }

    func cancelOpenOnConfirmation() { opensChannel = false }

    func takeConfirmationPresentation() -> Confirmation? {
        guard let confirmation, presentedConfirmationID != confirmation.id else { return nil }
        presentedConfirmationID = confirmation.id
        return confirmation
    }

    func beginPresentation() {
        guard confirmation != nil else { return }
        confirmation = nil
        submission = nil
        error = nil
        editedUnconfirmedMessage = false
    }

    func reconcileDelivery() {
        guard let submission, draft.sendAttemptID == submission.id else { return }
        if let message = store.messages.first(where: { $0.id == submission.id }) {
            confirm(id: message.id, sequence: message.sequence)
        } else if attempt?.phase == .confirmed {
            confirm(id: submission.id, sequence: nil)
        }
    }

    private func confirm(id: String, sequence: Int?) {
        guard let submission, submission.id == id, draft.sendAttemptID == id, confirmation == nil else { return }
        draft.clear(ifUnchanged: submission.revision)
        confirmation = .init(id: id, sequence: sequence, opensChannel: opensChannel)
        observation = UUID()
    }

    private func observeDelivery() {
        let token = UUID()
        observation = token
        withObservationTracking {
            reconcileDelivery()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observation == token, self.confirmation == nil else { return }
                self.observeDelivery()
            }
        }
    }
}
