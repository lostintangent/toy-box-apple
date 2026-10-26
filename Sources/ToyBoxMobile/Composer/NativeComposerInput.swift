import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ComposerCompletionKey {
    case previous, next, accept, dismiss
}

@MainActor @Observable
final class ComposerEditorState {
    var selection = NSRange(location: 0, length: 0)
    private(set) var hasMarkedText = false
    private(set) var isFocused = false
    @ObservationIgnored weak var textView: ComposerTextView?

    func focus() { textView?.becomeFirstResponder() }

    @discardableResult
    func replace(_ range: NSRange, with text: String) -> Bool {
        guard let textView, textView.markedTextRange == nil,
              range.location >= 0, range.length >= 0,
              range.location <= textView.text.utf16.count,
              range.length <= textView.text.utf16.count - range.location else { return false }
        textView.selectedRange = range
        textView.insertText(text)
        return true
    }

    fileprivate func update(from textView: UITextView) {
        selection = textView.selectedRange
        hasMarkedText = textView.markedTextRange != nil
        isFocused = textView.isFirstResponder
    }
}

struct NativeComposerInput: UIViewRepresentable {
    @Binding var text: String
    let editor: ComposerEditorState
    var completionIsVisible = false
    var isEditable = true
    var onSend: () -> Void
    var onCompletionKey: (ComposerCompletionKey) -> Bool
    var onPasteImages: ([NSItemProvider]) -> Void
    var onEscape: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 0, right: 12)
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .default
        view.accessibilityLabel = "Message"
        view.delegate = context.coordinator
        view.text = text
        configure(view)
        view.selectedRange = clampedSelection(for: view)
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        if context.coordinator.parent.editor !== editor {
            view.unmarkText()
            context.coordinator.textViewDidChange(view)
            context.coordinator.parent.editor.textView = nil
            view.undoManager?.removeAllActions()
            view.text = text
            view.selectedRange = clampedSelection(for: view)
        }
        context.coordinator.parent = self
        configure(view)
        guard view.markedTextRange == nil else { return }
        if view.text != text {
            view.text = text
            view.invalidateIntrinsicContentSize()
        }
        let selection = clampedSelection(for: view)
        if view.selectedRange != selection { view.selectedRange = selection }
    }

    static func dismantleUIView(_ view: ComposerTextView, coordinator: Coordinator) {
        if coordinator.parent.editor.textView === view { coordinator.parent.editor.textView = nil }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let font = uiView.font else { return nil }
        let natural = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let minimum = ceil(font.lineHeight + insets)
        let maximum = ceil(3 * font.lineHeight + insets)
        uiView.isScrollEnabled = natural.height > maximum
        return CGSize(width: width, height: min(maximum, max(minimum, natural.height)))
    }

    private func configure(_ view: ComposerTextView) {
        editor.textView = view
        view.isEditable = isEditable
        view.completionIsVisible = completionIsVisible
        view.onSend = onSend
        view.onCompletionKey = onCompletionKey
        view.onPasteImages = onPasteImages
        view.onEscape = onEscape
    }

    private func clampedSelection(for view: UITextView) -> NSRange {
        let length = view.text.utf16.count
        let location = min(max(editor.selection.location, 0), length)
        return NSRange(location: location, length: min(max(editor.selection.length, 0), length - location))
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeComposerInput

        init(parent: NativeComposerInput) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.editor.update(from: textView)
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.editor.update(from: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.editor.update(from: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.editor.update(from: textView)
        }
    }
}

final class ComposerTextView: UITextView {
    var completionIsVisible = false
    var onSend: (() -> Void)?
    var onCompletionKey: ((ComposerCompletionKey) -> Bool)?
    var onPasteImages: (([NSItemProvider]) -> Void)?
    var onEscape: (() -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        textColor = .label
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        textColor = .label
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            command("\r", action: #selector(hardwareReturn)),
            command("\r", modifiers: .command, action: #selector(sendMessage)),
        ]
        if completionIsVisible {
            commands += [
                command(UIKeyCommand.inputUpArrow, action: #selector(previousCompletion)),
                command(UIKeyCommand.inputDownArrow, action: #selector(nextCompletion)),
                command("\t", action: #selector(acceptCompletion)),
            ]
        }
        if completionIsVisible || onEscape != nil {
            commands.append(command(UIKeyCommand.inputEscape, action: #selector(dismissCompletion)))
        }
        return commands + (super.keyCommands ?? [])
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if [#selector(hardwareReturn), #selector(sendMessage),
            #selector(previousCompletion), #selector(nextCompletion),
            #selector(acceptCompletion), #selector(dismissCompletion)].contains(action) {
            return isEditable && markedTextRange == nil
        }
        if action == #selector(paste(_:)), !imageProviders.isEmpty { return isEditable }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let providers = imageProviders
        guard isEditable, !providers.isEmpty, let onPasteImages else {
            super.paste(sender)
            return
        }
        onPasteImages(providers)
    }

    private var imageProviders: [NSItemProvider] {
        UIPasteboard.general.itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
    }

    private func command(_ input: String, modifiers: UIKeyModifierFlags = [],
                         action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc func hardwareReturn() {
        guard markedTextRange == nil else { return }
        if onCompletionKey?(.accept) == true { return }
        onSend?()
    }

    @objc func sendMessage() {
        guard markedTextRange == nil else { return }
        onSend?()
    }

    @objc private func previousCompletion() { _ = onCompletionKey?(.previous) }
    @objc private func nextCompletion() { _ = onCompletionKey?(.next) }
    @objc private func acceptCompletion() { _ = onCompletionKey?(.accept) }
    @objc private func dismissCompletion() {
        if onCompletionKey?(.dismiss) != true { onEscape?() }
    }
}
