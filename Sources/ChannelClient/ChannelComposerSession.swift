import ChannelKit
import Foundation
import Observation

@MainActor @Observable
public final class ChannelComposerSession {
    public struct ReplySource {
        public let name: String
        public let sequence: Int
    }

    public static let appendExplanation = "Your newer draft will not be replaced. Appending preserves both messages. Sending edited text creates a new message, and an earlier unconfirmed send may already have arrived."

    public let store: ChannelStore
    public let draft: ComposerDraft
    public var replySource: ReplySource?
    public var pendingEdit: ChannelSendAttempt?
    public private(set) var isSubmitting = false
    private var submissionError: (revision: UUID, message: String)?

    public init(store: ChannelStore, draft: ComposerDraft) {
        self.store = store
        self.draft = draft
    }

    public var attempt: ChannelSendAttempt? {
        guard let id = draft.sendAttemptID else { return nil }
        return store.sendAttempts.first { $0.id == id }
    }

    public func canSend(hasAdditionalContent: @autoclosure () -> Bool = false,
                        isLoadingAdditionalImages: @autoclosure () -> Bool = false) -> Bool {
        channelCanSend(
            isLive: store.phase.isLive, isSending: store.isSending, isSubmitting: isSubmitting,
            hasContent: draft.hasContent || hasAdditionalContent(),
            isLoadingImages: draft.isLoadingImages || isLoadingAdditionalImages(),
            hasUnreadableImage: draft.hasUnreadableImage, textUTF16Count: draft.text.utf16.count
        ) && attempt?.phase != .confirmed
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
        guard canSend() else { return false }
        let content = draft.text
        let attachments = draft.images.map(\.attachment)
        let revision = draft.revision
        let id = draft.sendAttemptID ?? UUID().uuidString
        draft.associateSend(id: id)
        submissionError = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await store.post(id: id, content: content, attachments: attachments)
            draft.clear(ifUnchanged: revision)
            if !draft.hasContent { replySource = nil }
            return true
        } catch {
            if store.sendAttempts.first(where: { $0.id == id })?.error == nil {
                submissionError = (revision, error.localizedDescription)
            }
            return false
        }
    }

    public func reconcile() {
        guard isConfirmed else { return }
        draft.clear(ifUnchanged: draft.revision)
        replySource = nil
        submissionError = nil
    }

    @discardableResult
    public func reply(to agent: ChannelAgent, sequence: Int? = nil,
                      insertingPrefix: ((String) -> Bool)? = nil) -> Bool {
        let prefix = "@\(agentHandleFromName(agent.name)) "
        if !draft.text.hasPrefix(prefix) {
            if let insertingPrefix {
                guard insertingPrefix(prefix) else { return false }
            } else {
                draft.text = prefix + draft.text
            }
        }
        if let sequence { replySource = .init(name: agent.name, sequence: sequence) }
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
