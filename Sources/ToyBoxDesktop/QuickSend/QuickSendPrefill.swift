import Foundation
import Observation

struct QuickSendPrefill: Identifiable, Sendable {
    var id = UUID()
    var text = ""
    var fileURLs: [URL] = []
    var images: [ComposerImage] = []

    func appending(_ other: QuickSendPrefill) -> QuickSendPrefill {
        .init(text: joinedComposerText(text, other.text), fileURLs: fileURLs + other.fileURLs,
              images: images + other.images)
    }
}

/// Incoming content is durable before a channel is chosen and never edits an immutable send.
@MainActor @Observable
final class QuickSendPrefillInbox {
    let draft: ComposerDraft
    private let allowsLocalPaths: Bool

    init(serverURL: URL, draft: ComposerDraft? = nil) {
        self.draft = draft ?? .shared(serverURL: serverURL, channelID: "", scope: .quickSendIncoming)
        allowsLocalPaths = Self.acceptsLocalPaths(serverURL: serverURL)
    }

    nonisolated static func acceptsLocalPaths(serverURL: URL) -> Bool {
        let host = ChannelFolders.normalizedHost(serverURL)
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.first == "127" && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && UInt8($0) != nil
        }
    }

    var hasPendingContent: Bool { draft.hasContent || draft.isLoadingImages || draft.error != nil }

    func receive(_ prefill: QuickSendPrefill) {
        draft.text = joinedComposerText(draft.text, prefill.text)
        for image in prefill.images {
            var copy = image
            copy.id = UUID()
            draft.append(copy)
        }
        draft.attachFiles(prefill.fileURLs, allowingLocalPaths: allowsLocalPaths)
    }

    @discardableResult
    func apply(to session: AuxiliaryComposerSession) -> Bool {
        guard hasPendingContent, !draft.isLoadingImages, !session.isReadOnly,
              !session.isSubmitting, session.confirmation == nil else { return false }
        let revision = draft.revision
        session.draft.append(contentsOf: draft)
        draft.clear(ifUnchanged: revision)
        draft.error = nil
        return true
    }
}
