import ChannelClient
import ChannelKit
import Foundation
import Observation

/// Presentation state only. The app's outbox owns each message once it's saved, so a send closes
/// the editor at once and its row in the channel shows the rest.
@MainActor @Observable
final class AuxiliaryComposerSession {
    struct Confirmation: Equatable {
        let id: String
        let opensChannel: Bool
    }

    private let composer: ChannelComposerSession
    private let connected: @MainActor () -> Bool
    let requestSequence: Int?
    private(set) var confirmation: Confirmation?
    private(set) var error: String?
    private var requestInvalidated = false
    private var replacementRequestSequence: Int?
    @ObservationIgnored var prepareForExternalEdit: (@MainActor () -> Void)?
    @ObservationIgnored private var presentedConfirmationID: String?

    var store: ChannelStore { composer.store }
    var draft: ComposerDraft { composer.draft }
    var isSubmitting: Bool { composer.isSubmitting }
    /// QuickSend and the menu bar send without opening the channel, so they pass the catalog's state.
    var isConnected: Bool { connected() }

    init(store: ChannelStore, scope: ComposerDraft.Scope, requester: ChannelAgent? = nil,
         draft: ComposerDraft? = nil, isConnected: (@MainActor () -> Bool)? = nil) {
        let draft = draft ?? .shared(serverURL: store.api.baseURL, channelID: store.id, scope: scope)
        let connected = isConnected ?? { [unowned store] in store.phase.isConnected }
        self.connected = connected
        composer = ChannelComposerSession(store: store, draft: draft, isConnected: connected)
        if case .inboxReply(let sequence) = scope { requestSequence = sequence }
        else { requestSequence = nil }
        if let requester { seedRequesterIfNew(requester) }
    }

    var requestChanged: Bool {
        requestSequence.map { requestInvalidated || (store.isLoaded && store.requestSequence != $0) } ?? false
    }

    func seedRequesterIfNew(_ requester: ChannelAgent) {
        guard draft.isNew, !draft.hasContent, requestSequence != nil else { return }
        draft.text = "@\(requester.handle) "
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

    /// `hasAdditionalContent` counts dictated words that Send will commit first.
    func canSend(hasAdditionalContent: Bool = false) -> Bool {
        composer.canSend(isBlocked: requestChanged || confirmation != nil, hasAdditionalContent: hasAdditionalContent)
    }

    func send(opensChannel: Bool = false) async {
        guard canSend() else {
            error = requestChanged ? "This request changed. Open the channel before replying."
                : "This message cannot be sent yet. Check the connection and attachments."
            return
        }
        error = nil
        guard let result = await composer.submit() else {
            error = composer.error.map { "Not sent. \($0)" }
            return
        }
        let id = switch result {
        case .committed(let message): message.id
        case .alreadyAccepted(let id): id
        }
        confirmation = .init(id: id, opensChannel: opensChannel)
    }

    func takeConfirmationPresentation() -> Confirmation? {
        guard let confirmation, presentedConfirmationID != confirmation.id else { return nil }
        presentedConfirmationID = confirmation.id
        return confirmation
    }

    func beginPresentation() {
        guard confirmation != nil else { return }
        confirmation = nil
        error = nil
    }
}
