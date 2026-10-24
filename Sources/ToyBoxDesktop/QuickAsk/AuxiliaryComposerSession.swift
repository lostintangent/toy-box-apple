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

    private struct Submission {
        let id: String
        let revision: UUID
        let content: String
        let attachments: [ChannelAttachment]
        var opensChannel: Bool
    }

    let store: ChannelStore
    let draft: ComposerDraft
    let requestSequence: Int?
    private(set) var isSubmitting = false
    private(set) var confirmation: Confirmation?
    private(set) var error: String?
    private(set) var editedUnconfirmedMessage = false
    private var submission: Submission?
    private var requestInvalidated = false
    @ObservationIgnored private var observation = UUID()

    init(store: ChannelStore, scope: ComposerDraft.Scope, requester: ChannelAgent? = nil,
         draft: ComposerDraft? = nil) {
        self.store = store
        self.draft = draft ?? .shared(serverURL: store.api.baseURL, channelID: store.id, scope: scope)
        if case .inboxReply(let sequence) = scope { requestSequence = sequence }
        else { requestSequence = nil }
        if let requester, self.draft.isNew, !self.draft.hasContent {
            self.draft.text = "@\(agentHandleFromName(requester.name)) "
        }
        if let id = self.draft.sendAttemptID {
            submission = .init(id: id, revision: self.draft.revision, content: self.draft.text,
                               attachments: self.draft.images.map(\.attachment), opensChannel: false)
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

    func invalidateRequest() { requestInvalidated = true }

    var isReadOnly: Bool { submission != nil && draft.sendAttemptID == submission?.id }

    var canSend: Bool {
        store.phase.isLive && !store.isSending && !isSubmitting && !requestChanged
            && confirmation == nil && draft.hasContent && !draft.isLoadingImages
            && !draft.hasUnreadableImage && draft.text.utf16.count <= 12_000
    }

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
        let previous = submission.flatMap { draft.sendAttemptID == $0.id ? $0 : nil }
        let next = previous ?? Submission(
            id: draft.sendAttemptID ?? UUID().uuidString, revision: draft.revision,
            content: draft.text, attachments: draft.images.map(\.attachment), opensChannel: opensChannel
        )
        submission = next
        submission?.opensChannel = opensChannel
        draft.associateSend(id: next.id)
        error = nil
        isSubmitting = true
        observeDelivery()
        defer { isSubmitting = false }
        do {
            let result = try await store.post(id: next.id, content: next.content, attachments: next.attachments)
            switch result {
            case .committed(let message): confirm(id: next.id, sequence: message.sequence)
            case .alreadyAccepted(let id): confirm(id: id, sequence: nil)
            }
        } catch {
            if confirmation == nil, submission?.id == next.id {
                self.error = self.attempt == nil ? "Not sent. \(error.localizedDescription)" : nil
            }
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

    func cancelOpenOnConfirmation() { submission?.opensChannel = false }

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
        confirmation = .init(id: id, sequence: sequence, opensChannel: submission.opensChannel)
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
