import ToyBoxClient
import ToyBoxKit
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
    var mentionHighlight: String?
    var dismissedMention: AgentMentions.Query?
    var restoresFocusAfterPresentation = false
    private var photoImportCount = 0
    var store: ChannelStore { composer.store }
    var draft: ComposerDraft { composer.draft }

    var mentionQuery: AgentMentions.Query? {
        guard editor.isFocused, !editor.hasMarkedText, !dictation.isSessionActive else { return nil }
        return .match(text: draft.text, selection: editor.selection)
    }

    var mentionChoices: [AgentMentions.Choice] {
        guard let query = mentionQuery, query != dismissedMention else { return [] }
        return AgentMentions.Choice.choices(matching: query.text, among: store.roster)
    }

    func preparePresentation() {
        restoresFocusAfterPresentation = editor.isFocused
        dictation.deactivate()
    }

    func presentCreate(_ name: String, using management: ManagementPresenter) {
        preparePresentation()
        if let target = store.target { management.present(.addMember(target, name: name)) }
    }

    func presentEdit(agentId: String, using management: ManagementPresenter) {
        preparePresentation()
        if let target = store.target { management.present(.editMember(target, agentId: agentId)) }
    }

    func acceptMention(_ choice: AgentMentions.Choice, using management: ManagementPresenter) {
        guard let query = mentionQuery else { return }
        if choice.isCreate {
            guard store.phase.isConnected else { return }
            dismissedMention = query
            presentCreate(choice.name, using: management)
        } else {
            editor.replace(query.range, with: "\(choice.handle) ")
        }
    }

    func handleMentionKey(_ key: ComposerCompletionKey, using management: ManagementPresenter) -> Bool {
        let choices = mentionChoices
        guard !choices.isEmpty else { return false }
        let index = choices.firstIndex { $0.id == mentionHighlight } ?? 0
        switch key {
        case .previous: mentionHighlight = choices[max(0, index - 1)].id
        case .next: mentionHighlight = choices[min(choices.count - 1, index + 1)].id
        case .accept: acceptMention(choices[index], using: management)
        case .dismiss: dismissedMention = mentionQuery
        }
        return true
    }

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
