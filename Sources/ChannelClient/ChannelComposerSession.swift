import ChannelKit
import Foundation
import Observation

@MainActor @Observable
public final class ChannelComposerSession {
    public static let appendExplanation = "Your newer draft will not be replaced. Appending preserves both messages. Sending edited text creates a new message, and an earlier unconfirmed send may already have arrived."

    public let store: ChannelStore
    public let draft: ComposerDraft
    public var pendingEdit: ChannelSendAttempt?
    public private(set) var isSubmitting = false
    private var submissionError: (revision: UUID, message: String)?
    /// Keeps the text and images after a send is recorded, so the caller clears them once it confirms the echo.
    private let keepsDraftUntilConfirmed: Bool

    public init(store: ChannelStore, draft: ComposerDraft, keepsDraftUntilConfirmed: Bool = false) {
        self.store = store
        self.draft = draft
        self.keepsDraftUntilConfirmed = keepsDraftUntilConfirmed
    }

    public var attempt: ChannelSendAttempt? {
        guard let id = draft.sendAttemptID else { return nil }
        return store.sendAttempts.first { $0.id == id }
    }

    public func canSend(isBlocked: @autoclosure () -> Bool = false,
                        hasAdditionalContent: @autoclosure () -> Bool = false,
                        isLoadingAdditionalImages: @autoclosure () -> Bool = false) -> Bool {
        // Connection comes first, so an offline session never observes what would block it.
        guard store.phase.isConnected, !isBlocked() else { return false }
        return !store.isSending && !isSubmitting
            && draft.isSendable(hasAdditionalContent: hasAdditionalContent(),
                                isLoadingAdditionalImages: isLoadingAdditionalImages())
            && attempt?.phase != .confirmed
    }

    public var isConfirmed: Bool {
        guard let id = draft.sendAttemptID else { return false }
        return attempt?.phase == .confirmed || store.messages.reversed().contains { $0.id == id }
    }

    public var error: String? {
        submissionError.flatMap { $0.revision == draft.revision ? $0.message : nil }
    }

    @discardableResult
    public func send() async -> Bool {
        await submit() != nil
    }

    public func submit() async -> ChannelSendResult? {
        guard canSend() else { return nil }
        let content = draft.text
        let attachments = draft.images.map(\.attachment)
        let revision = draft.revision
        let id = draft.sendAttemptID ?? UUID().uuidString
        draft.associateSend(id: id)
        submissionError = nil
        isSubmitting = true
        defer { isSubmitting = false }
        var recorded = false
        do {
            let result = try await store.post(id: id, content: content, attachments: attachments) { [self] in
                recorded = true
                if !keepsDraftUntilConfirmed { clearSentDraft(revision: revision) }
            }
            if !keepsDraftUntilConfirmed { clearSentDraft(revision: revision) }
            return result
        } catch {
            if !recorded, store.sendAttempts.first(where: { $0.id == id })?.error == nil {
                submissionError = (revision, error.localizedDescription)
            }
            return nil
        }
    }

    private func clearSentDraft(revision: UUID) {
        draft.clear(ifUnchanged: revision)
    }

    public func reconcile() {
        guard isConfirmed else { return }
        draft.clear(ifUnchanged: draft.revision)
        submissionError = nil
    }

    @discardableResult
    public func reply(to agent: ChannelAgent, insertingPrefix: ((String) -> Bool)? = nil) -> Bool {
        let prefix = "@\(agent.handle) "
        guard !draft.text.hasPrefix(prefix) else { return true }
        if let insertingPrefix {
            return insertingPrefix(prefix)
        }
        draft.text = prefix + draft.text
        return true
    }

    @discardableResult
    public func edit(_ attempt: ChannelSendAttempt) -> Bool {
        if draft.hasContent && (draft.text.trimmingCharacters(in: .whitespacesAndNewlines) != attempt.content
                                || draft.images.map(\.attachment) != attempt.attachments) {
            pendingEdit = attempt
            return false
        }
        draft.restore(content: attempt.content, attachments: attempt.attachments, sendAttemptID: attempt.id)
        pendingEdit = nil
        return true
    }

    @discardableResult
    public func appendPendingEdit() -> Bool {
        guard let pendingEdit else { return false }
        draft.append(content: pendingEdit.content, attachments: pendingEdit.attachments)
        self.pendingEdit = nil
        return true
    }
}
