@testable import ChannelClient
import ChannelKit
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import ToyBoxMobile

@MainActor
struct ComposerTests {
    @Test func softwareReturnInsertsANewlineWhileHardwareReturnSendsUnlessCompletionConsumesIt() {
        let view = ComposerTextView()
        var sends = 0
        var accepted = 0
        view.onSend = { sends += 1 }
        view.onCompletionKey = { [weak view] key in
            if view?.completionIsVisible == true, case .accept = key { accepted += 1; return true }
            return false
        }
        view.insertText("A draft")
        view.insertText("\n")
        #expect(view.text == "A draft\n")
        #expect(sends == 0)
        view.hardwareReturn()
        #expect(sends == 1)
        view.completionIsVisible = true
        view.hardwareReturn()
        #expect(accepted == 1)
        #expect(sends == 1)
        view.sendMessage()
        #expect(sends == 2)
        view.completionIsVisible = false
        view.onCompletionKey = { _ in accepted += 1; return true }
        view.hardwareReturn()
        #expect(accepted == 2)
        #expect(sends == 2)
        let returns = view.keyCommands?.filter {
            $0.action == #selector(ComposerTextView.hardwareReturn)
                || $0.action == #selector(ComposerTextView.sendMessage)
        } ?? []
        #expect(returns.contains { $0.modifierFlags.isEmpty })
        #expect(returns.contains { $0.modifierFlags == .command })
        #expect(!returns.contains { $0.modifierFlags == .shift || $0.modifierFlags == .alternate })
    }

    @Test func markedTextCannotDispatchOrAcceptAMention() {
        let view = ComposerTextView()
        var sends = 0
        var completions = 0
        view.onSend = { sends += 1 }
        view.onCompletionKey = { _ in completions += 1; return true }
        view.completionIsVisible = true
        view.setMarkedText("\u{306B}", selectedRange: NSRange(location: 1, length: 0))
        #expect(view.markedTextRange != nil)
        view.hardwareReturn()
        view.sendMessage()
        #expect(sends == 0)
        #expect(completions == 0)
        #expect(!view.canPerformAction(#selector(ComposerTextView.hardwareReturn), withSender: nil))
        #expect(!view.canPerformAction(#selector(ComposerTextView.sendMessage), withSender: nil))
        view.unmarkText()
        view.hardwareReturn()
        #expect(completions == 1)
        #expect(sends == 0)
    }

    @Test func mentionInsertionUsesNativeEditingAndKeepsTheCaretAfterTheInsertedSpace() {
        let editor = ComposerEditorState()
        let view = ComposerTextView()
        editor.textView = view
        view.text = "Hello @ad"
        #expect(editor.replace(NSRange(location: 6, length: 3), with: "@ada "))
        #expect(view.text == "Hello @ada ")
        #expect(view.selectedRange == NSRange(location: 11, length: 0))
        #expect(!editor.replace(NSRange(location: 20, length: 1), with: "Out of range"))
        #expect(view.text == "Hello @ada ")
        view.setMarkedText("\u{306B}", selectedRange: NSRange(location: 1, length: 0))
        #expect(!editor.replace(NSRange(location: 0, length: 1), with: "Blocked"))
    }

    @Test func nativeUndoAndRedoKeepTheBoundTextInSync() throws {
        var text = ""
        let editor = ComposerEditorState()
        let input = NativeComposerInput(
            text: Binding(get: { text }, set: { text = $0 }), editor: editor,
            onSend: {}, onCompletionKey: { _ in false }, onPasteImages: { _ in }
        )
        let coordinator = NativeComposerInput.Coordinator(parent: input)
        let view = ComposerTextView()
        view.delegate = coordinator
        view.insertText("An ordinary native edit")
        #expect(text == view.text)
        #expect(!text.isEmpty)
        let undo = try #require(view.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(view.text.isEmpty)
        #expect(text == view.text)
        undo.redo()
        #expect(view.text == "An ordinary native edit")
        #expect(text == view.text)
    }

    @Test func imagePasteUsesTheSharedImportCallbackWithoutReplacingText() throws {
        let pasteboard = UIPasteboard.general
        let original = pasteboard.items
        defer { pasteboard.items = original }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        pasteboard.setData(try #require(image.pngData()), forPasteboardType: UTType.png.identifier)
        let view = ComposerTextView()
        view.text = "Keep this draft"
        var imported = 0
        view.onPasteImages = { imported += $0.count }
        #expect(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        view.paste(nil)
        #expect(imported == 1)
        #expect(view.text == "Keep this draft")
    }

    @Test func replyContextUsesTheSourceAndAnOldEchoCannotClearNewerWords() throws {
        let draft = ComposerDraft(imageIsReadable: { UIImage(data: $0) != nil })
        draft.text = "Keep these words"
        let store = ChannelStore(id: "test", api: try ChannelAPI(serverURL: "http://localhost:3210"),
                                 sendJournal: nil)
        let session = ComposerSession(store: store, draft: draft)
        let agent = ChannelAgent(id: "ada", name: "Ada Lovelace")
        session.reply(to: agent, sequence: 8)
        #expect(draft.text == "@ada-lovelace Keep these words")
        #expect(session.replySource?.sequence == 8)
        session.reply(to: agent, sequence: nil)
        #expect(draft.text == "@ada-lovelace Keep these words")
        draft.associateSend(id: "original")
        draft.text = "A newer draft"
        let message = ChannelMessage(id: "original", sequence: 9, timestamp: "2026-10-24T00:00:00Z",
                                     sender: .user, content: .text("The earlier payload"))
        let channel = Channel(id: "test", name: "Test", model: .init(provider: "test", name: "test"),
                              latestSequence: 9, updatedAt: message.timestamp)
        let state = ChannelState(revision: 1, channel: channel,
                                 lead: .init(id: "lead", name: "Lead"), messages: [message])
        _ = try store.apply(.init(type: "snapshot", state: state))
        session.reconcile()
        #expect(draft.text == "A newer draft")
        #expect(session.replySource?.sequence == 8)
    }
}
