import ChannelClient
import ChannelKit
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable
final class ComposerSession {
    struct ReplySource {
        let name: String
        let sequence: Int
    }

    private static var sessions: [ObjectIdentifier: ComposerSession] = [:]

    let store: ChannelStore
    let draft: ComposerDraft
    let editor = ComposerEditorState()
    var replySource: ReplySource?
    var pendingEdit: ChannelSendAttempt?
    private(set) var isSubmitting = false
    private var photoImportCount = 0
    private var submissionError: (revision: UUID, message: String)?

    static func shared(store: ChannelStore) -> ComposerSession {
        let key = ObjectIdentifier(store)
        if let session = sessions[key] { return session }
        let session = ComposerSession(store: store)
        sessions[key] = session
        return session
    }

    init(store: ChannelStore, draft: ComposerDraft? = nil) {
        self.store = store
        self.draft = draft ?? .shared(serverURL: store.api.baseURL, channelID: store.id,
                                      imageIsReadable: Self.imageIsReadable)
        editor.selection = NSRange(location: self.draft.text.utf16.count, length: 0)
    }

    var isLoadingImages: Bool { photoImportCount > 0 || draft.isLoadingImages }

    var attempt: ChannelSendAttempt? {
        guard let id = draft.sendAttemptID else { return nil }
        return store.sendAttempts.first { $0.id == id }
    }

    var canSend: Bool {
        !editor.hasMarkedText && channelCanSend(
            isLive: store.phase.isLive, isSending: store.isSending, isSubmitting: isSubmitting,
            hasContent: draft.hasContent, isLoadingImages: isLoadingImages,
            hasUnreadableImage: draft.hasUnreadableImage, textUTF16Count: draft.text.utf16.count
        ) && attempt?.phase != .confirmed
    }

    var isConfirmed: Bool {
        guard let id = draft.sendAttemptID else { return false }
        return attempt?.phase == .confirmed || store.messages.contains { $0.id == id }
    }

    var error: String? {
        submissionError.flatMap { $0.revision == draft.revision ? $0.message : nil }
    }

    @discardableResult
    func send() async -> Bool {
        guard canSend else { return false }
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

    func reconcile() {
        guard isConfirmed else { return }
        draft.clear(ifUnchanged: draft.revision)
        replySource = nil
        submissionError = nil
    }

    func reply(to agent: ChannelAgent, sequence: Int?) {
        let prefix = "@\(agentHandleFromName(agent.name)) "
        if !draft.text.hasPrefix(prefix) {
            if !editor.replace(NSRange(location: 0, length: 0), with: prefix) {
                draft.text = prefix + draft.text
                editor.selection = NSRange(location: prefix.utf16.count, length: 0)
            }
        }
        if let sequence { replySource = .init(name: agent.name, sequence: sequence) }
        editor.focus()
    }

    func edit(_ attempt: ChannelSendAttempt) {
        if draft.hasContent && (draft.text.trimmingCharacters(in: .whitespacesAndNewlines) != attempt.content
                                || draft.images.map(\.attachment) != attempt.attachments) {
            pendingEdit = attempt
            return
        }
        draft.restore(content: attempt.content, attachments: attempt.attachments, sendAttemptID: attempt.id)
        editor.selection = NSRange(location: draft.text.utf16.count, length: 0)
        editor.focus()
    }

    func appendPendingEdit() {
        guard let pendingEdit else { return }
        let recovered = ComposerDraft(imageIsReadable: Self.imageIsReadable)
        recovered.restore(content: pendingEdit.content, attachments: pendingEdit.attachments)
        draft.append(contentsOf: recovered)
        self.pendingEdit = nil
        editor.selection = NSRange(location: draft.text.utf16.count, length: 0)
        editor.focus()
    }

    func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        photoImportCount += 1
        defer { photoImportCount -= 1 }
        var failures: [String] = []
        for (index, item) in items.enumerated() {
            guard let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }),
                  let mimeType = type.preferredMIMEType else {
                failures.append("Photo \(index + 1): Only images can be attached.")
                continue
            }
            let name = "Photo \(index + 1).\(type.preferredFilenameExtension ?? "image")"
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    draft.append(.init(name: name, mimeType: mimeType, data: data))
                } else {
                    failures.append("\(name): No readable image data was provided.")
                }
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { draft.error = failures.joined(separator: "\n") }
    }

    private static func imageIsReadable(_ data: Data) -> Bool { UIImage(data: data) != nil }
}
