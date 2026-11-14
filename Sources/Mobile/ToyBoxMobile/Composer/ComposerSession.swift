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
    let dictation: Dictation
    let editor = ComposerEditor()
    private var photoImportCount = 0
    var store: ChannelStore { composer.store }
    var draft: ComposerDraft { composer.draft }

    init(store: ChannelStore, draft: ComposerDraft? = nil, dictationSystem: DictationSystem? = nil) {
        composer = ChannelComposerSession(
            store: store, draft: draft ?? .shared(serverURL: store.api.baseURL, channelID: store.id,
                                                 imageIsReadable: Self.imageIsReadable)
        )
        dictation = Dictation(system: dictationSystem ?? .live)
        dictation.draftRevision = { [draft = self.draft] in draft.revision }
        editor.selection = NSRange(location: self.draft.text.utf16.count, length: 0)
    }

    var isLoadingImages: Bool { photoImportCount > 0 || draft.isLoadingImages }

    var canSend: Bool {
        !editor.hasMarkedText && !dictation.holdsSend
            && composer.canSend(hasAdditionalContent: dictation.hasWords,
                                isLoadingAdditionalImages: photoImportCount > 0)
    }

    @discardableResult
    func send() async -> Bool {
        guard canSend else { return false }
        // A mic still preparing stops, rather than carrying into the fresh draft.
        if !dictation.isSessionActive, dictation.phase != .idle { dictation.deactivate() }
        guard await dictation.stop(.send) else { return false }
        return await composer.send() != nil
    }

    func reply(to agent: ChannelAgent) {
        dictation.commitNow()
        let insertion: (String) -> Bool = { [editor, draft] prefix in
            if editor.textView != nil { return editor.replace(NSRange(location: 0, length: 0), with: prefix) }
            draft.text = prefix + draft.text
            editor.selection = NSRange(location: prefix.utf16.count, length: 0)
            return true
        }
        if composer.reply(to: agent, insertingPrefix: insertion) { editor.focus() }
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

    static func imageIsReadable(_ data: Data) -> Bool { UIImage(data: data) != nil }
}
