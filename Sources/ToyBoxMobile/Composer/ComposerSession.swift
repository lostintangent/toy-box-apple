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
    let composer: ChannelComposerSession
    let dictation: ComposerDictation
    let editor = ComposerEditorState()
    private var photoImportCount = 0
    private(set) var isFinalizingDictation = false
    var store: ChannelStore { composer.store }
    var draft: ComposerDraft { composer.draft }

    init(store: ChannelStore, draft: ComposerDraft? = nil, dictationSystem: DictationSystem? = nil) {
        composer = ChannelComposerSession(
            store: store, draft: draft ?? .shared(serverURL: store.api.baseURL, channelID: store.id,
                                                 imageIsReadable: Self.imageIsReadable)
        )
        dictation = ComposerDictation(system: dictationSystem ?? .live)
        dictation.draftRevision = { [draft = self.draft] in draft.revision }
        editor.selection = NSRange(location: self.draft.text.utf16.count, length: 0)
    }

    var isLoadingImages: Bool { photoImportCount > 0 || draft.isLoadingImages }

    var canSend: Bool {
        !editor.hasMarkedText && !isFinalizingDictation
            && composer.canSend(hasAdditionalContent: dictation.hasWords,
                                isLoadingAdditionalImages: photoImportCount > 0)
    }

    @discardableResult
    func send() async -> Bool {
        guard canSend else { return false }
        if dictation.isSessionActive {
            isFinalizingDictation = true
            let finalized = await dictation.stop(.send)
            isFinalizingDictation = false
            guard finalized else { return false }
        } else if dictation.phase != .idle {
            dictation.deactivate()
        }
        dictation.draftSent()
        return await composer.send()
    }

    func reply(to agent: ChannelAgent, sequence: Int?) {
        dictation.commitNow()
        let insertion: (String) -> Bool = { [editor, draft] prefix in
            if editor.textView != nil { return editor.replace(NSRange(location: 0, length: 0), with: prefix) }
            draft.text = prefix + draft.text
            editor.selection = NSRange(location: prefix.utf16.count, length: 0)
            return true
        }
        if composer.reply(to: agent, sequence: sequence, insertingPrefix: insertion) { editor.focus() }
    }

    func edit(_ attempt: ChannelSendAttempt) {
        dictation.commitNow()
        guard composer.edit(attempt) else { return }
        editor.selection = NSRange(location: draft.text.utf16.count, length: 0)
        editor.focus()
    }

    func appendPendingEdit() {
        dictation.commitNow()
        guard composer.appendPendingEdit() else { return }
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
