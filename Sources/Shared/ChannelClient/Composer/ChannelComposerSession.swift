import ChannelKit
import Foundation
import Observation

@MainActor @Observable
public final class ChannelComposerSession {
    public let store: ChannelStore
    public let draft: ComposerDraft
    public private(set) var isSubmitting = false
    private let isConnected: @MainActor () -> Bool

    /// `isConnected` is the channel's own connection by default. QuickSend and the menu bar pass the
    /// catalog's, since they send without opening the channel.
    public init(store: ChannelStore, draft: ComposerDraft, isConnected: (@MainActor () -> Bool)? = nil) {
        self.store = store
        self.draft = draft
        self.isConnected = isConnected ?? { [unowned store] in store.phase.isConnected }
    }

    /// The outbox queues several messages in order, so only the save itself holds Send.
    public func canSend(isBlocked: @autoclosure () -> Bool = false,
                        hasAdditionalContent: @autoclosure () -> Bool = false,
                        isLoadingAdditionalImages: @autoclosure () -> Bool = false) -> Bool {
        // Connection comes first, so an offline session never observes what would block it.
        guard isConnected(), !isBlocked(), store.outbox != nil else { return false }
        return !isSubmitting && draft.isSendable(hasAdditionalContent: hasAdditionalContent(),
                                                 isLoadingAdditionalImages: isLoadingAdditionalImages())
    }

    /// Hands the draft to the outbox and clears it once the message is saved, unless it changed
    /// meanwhile. Returns the message's ID.
    @discardableResult
    public func send() async -> UUID? {
        guard canSend(), let outbox = store.outbox else { return nil }
        let revision = draft.revision
        isSubmitting = true
        defer { isSubmitting = false }
        let id = await outbox.send(draft.text, attachments: draft.images.map(\.attachment),
                                   to: store.id, on: store.api.baseURL)
        draft.clear(ifUnchanged: revision)
        return id
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
}
