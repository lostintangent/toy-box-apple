import ChannelClient
import Observation
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ComposerCompletionKey {
    case previous, next, accept, dismiss
}

struct ComposerReaderFocus {
    private(set) var isCovered = false
    private var restoresFocus = false

    mutating func cover(ownsFocus: Bool) {
        guard !isCovered else { return }
        isCovered = true
        restoresFocus = ownsFocus
    }

    mutating func uncover(canRestoreFocus: Bool) -> Bool {
        let restore = isCovered && restoresFocus && canRestoreFocus
        self = Self()
        return restore
    }

    mutating func cancelRestoration() { restoresFocus = false }
}

@MainActor @Observable
final class ComposerEditorState {
    var selection = NSRange(location: 0, length: 0)
    private(set) var hasMarkedText = false
    private(set) var isFocused = false
    private var readerFocus = ComposerReaderFocus()
    var isReaderCovered: Bool { readerFocus.isCovered }
    @ObservationIgnored private var allowsEditing = true
    @ObservationIgnored weak var textView: ComposerTextView?

    func focus() {
        guard !isReaderCovered, allowsEditing else { return }
        textView?.becomeFirstResponder()
    }

    func setReaderCovered(_ covered: Bool, canRestoreFocus: Bool) {
        if covered {
            readerFocus.cover(ownsFocus: textView?.isFirstResponder == true)
            textView?.resignFirstResponder()
            if let textView { update(from: textView) }
            setEditingAllowed(allowsEditing)
        } else {
            let restore = readerFocus.uncover(canRestoreFocus: canRestoreFocus)
            setEditingAllowed(allowsEditing)
            if restore { focus() }
        }
    }

    func setEditingAllowed(_ allowed: Bool) {
        allowsEditing = allowed
        textView?.isEditable = allowed && !isReaderCovered
    }

    func cancelReaderFocusRestoration() { readerFocus.cancelRestoration() }

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
    var dictation: ComposerDictation? = nil

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
        configure(view, coordinator: context.coordinator)
        context.coordinator.lastModelText = text
        view.selectedRange = clampedSelection(for: view)
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        if context.coordinator.parent.editor !== editor {
            context.coordinator.parent.dictation?.commitNow()
            view.unmarkText()
            context.coordinator.textViewDidChange(view)
            context.coordinator.parent.editor.cancelReaderFocusRestoration()
            context.coordinator.parent.editor.textView = nil
            view.undoManager?.removeAllActions()
            view.text = text
            view.selectedRange = clampedSelection(for: view)
        }
        context.coordinator.parent = self
        configure(view, coordinator: context.coordinator)
        guard view.markedTextRange == nil else { return }
        if context.coordinator.dictationSession != nil {
            if text == context.coordinator.lastModelText { return }
            context.coordinator.abandonDictation()
        }
        if view.text != text {
            view.text = text
            view.invalidateIntrinsicContentSize()
        }
        let selection = clampedSelection(for: view)
        if view.selectedRange != selection { view.selectedRange = selection }
        context.coordinator.lastModelText = text
    }

    static func dismantleUIView(_ view: ComposerTextView, coordinator: Coordinator) {
        coordinator.parent.dictation?.commitNow()
        if coordinator.parent.editor.textView === view {
            coordinator.parent.editor.cancelReaderFocusRestoration()
            coordinator.parent.editor.textView = nil
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView,
                      context: Context) -> CGSize? {
        uiView.composerSizeThatFits(proposal)
    }

    private func configure(_ view: ComposerTextView, coordinator: Coordinator) {
        coordinator.input = view
        view.coordinator = coordinator
        editor.textView = view
        dictation?.target = coordinator
        editor.setEditingAllowed(isEditable)
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
        private static let logger = Logger(subsystem: "dev.toybox.mobile", category: "Dictation")
        var parent: NativeComposerInput
        weak var input: ComposerTextView?
        var lastModelText = ""
        var dictationSession: DictationSession?
        var isApplyingDictation = false

        struct DictationSession {
            let base: String
            let replaced: NSRange
            let replacedText: String
            let attributes: [NSAttributedString.Key: Any]
            var span: NSRange
        }

        init(parent: NativeComposerInput) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingDictation else { return }
            parent.editor.update(from: textView)
            lastModelText = textView.text
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

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            commitDictationBeforeEdit()
            return true
        }
    }
}

extension NativeComposerInput.Coordinator: DictationTextTarget {
    var isInKeyWindow: Bool { input?.window?.isKeyWindow == true }

    func beginDictation() -> Bool {
        guard let input, input.window != nil, input.isEditable,
              !parent.editor.isReaderCovered,
              input.isFirstResponder || input.becomeFirstResponder() else { return false }
        input.unmarkText()
        anchorDictation()
        return dictationSession != nil
    }

    func anchorDictation() {
        guard let input, dictationSession == nil else { return }
        let range = input.selectedRange
        guard nativeRange(in: input, for: range) != nil else {
            Self.logger.error("Dictation could not anchor because the native selection is outside the draft.")
            return
        }
        var attributes = input.typingAttributes
        attributes[.foregroundColor] = UIColor.label
        dictationSession = .init(
            base: input.text, replaced: range, replacedText: (input.text as NSString).substring(with: range),
            attributes: attributes, span: range
        )
    }

    func showDictation(_ transcript: DictationTranscript) {
        guard let input, var session = dictationSession else { return }
        let (previous, next) = neighbors(of: session)
        let visible = transcript.visible
        let display = NSMutableAttributedString()
        var trailingLength = 0
        if visible.isEmpty {
            display.append(NSAttributedString(string: session.replacedText, attributes: session.attributes))
        } else {
            let (leading, trailing) = DictationTranscript.padding(for: visible, after: previous, before: next)
            var tentative = session.attributes
            tentative[.foregroundColor] = UIColor.secondaryLabel
            display.append(NSAttributedString(string: leading + transcript.finalized, attributes: session.attributes))
            display.append(NSAttributedString(string: String(visible.dropFirst(transcript.finalized.count)) + trailing,
                                              attributes: tentative))
            trailingLength = trailing.utf16.count
        }
        let selection = input.selectedRange
        let old = session.span
        isApplyingDictation = true
        guard replaceDictationDisplay(in: input, range: old, with: display) else {
            recoverDictation(session, finalized: visible)
            return
        }
        session.span = NSRange(location: old.location, length: display.length)
        dictationSession = session
        restoreSelection(selection, replacing: old, with: session.span,
                         caret: visible.isEmpty ? session.span
                            : NSRange(location: NSMaxRange(session.span) - trailingLength, length: 0))
        input.typingAttributes = session.attributes
        isApplyingDictation = false
        let model = dictatedText(session, finalized: transcript.finalized)
        lastModelText = model
        if parent.text != model { parent.text = model }
        parent.editor.update(from: input)
        input.invalidateIntrinsicContentSize()
        input.scrollRangeToVisible(input.selectedRange)
    }

    func endDictation(_ finalized: String) {
        guard let session = dictationSession else { return }
        dictationSession = nil
        guard let input else {
            parent.text = dictatedText(session, finalized: finalized)
            return
        }
        let selection = input.selectedRange
        isApplyingDictation = true
        guard replaceDictationDisplay(
            in: input, range: session.span,
            with: NSAttributedString(string: session.replacedText, attributes: session.attributes)
        ) else {
            recoverDictation(session, finalized: finalized)
            return
        }
        input.typingAttributes = session.attributes
        let (previous, next) = neighbors(of: session)
        let (leading, trailing) = DictationTranscript.padding(for: finalized, after: previous, before: next)
        let words = finalized.isEmpty ? session.replacedText : leading + finalized + trailing
        if !finalized.isEmpty {
            guard let range = nativeRange(in: input, for: session.replaced) else {
                recoverDictation(session, finalized: finalized)
                return
            }
            input.replace(range, withText: words)
            input.undoManager?.setActionName("Dictation")
        }
        restoreSelection(
            selection, replacing: session.span,
            with: NSRange(location: session.replaced.location, length: words.utf16.count),
            caret: finalized.isEmpty ? session.replaced
                : NSRange(location: session.replaced.location + words.utf16.count - trailing.utf16.count, length: 0)
        )
        isApplyingDictation = false
        lastModelText = input.text
        parent.text = input.text
        parent.editor.update(from: input)
        input.invalidateIntrinsicContentSize()
    }

    func commitDictationBeforeEdit() {
        guard dictationSession != nil, !isApplyingDictation else { return }
        parent.dictation?.commitNow()
    }

    func abandonDictation() {
        guard let input, let session = dictationSession else { return }
        dictationSession = nil
        isApplyingDictation = true
        if !replaceDictationDisplay(
            in: input, range: session.span,
            with: NSAttributedString(string: session.replacedText, attributes: session.attributes)
        ) {
            Self.logger.error("Dictation lost its native range while applying a replacement draft. Keeping the replacement draft.")
        }
        input.typingAttributes = session.attributes
        isApplyingDictation = false
        parent.dictation?.commitNow()
    }

    private func replaceDictationDisplay(
        in input: ComposerTextView, range: NSRange, with replacement: NSAttributedString
    ) -> Bool {
        guard let nativeRange = nativeRange(in: input, for: range) else { return false }
        let undo = input.undoManager
        undo?.disableUndoRegistration()
        defer { undo?.enableUndoRegistration() }
        input.replace(nativeRange, withAttributedText: replacement)
        return true
    }

    private func nativeRange(in input: UITextView, for range: NSRange) -> UITextRange? {
        let length = input.text.utf16.count
        guard range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location,
              let start = input.position(from: input.beginningOfDocument, offset: range.location),
              let end = input.position(from: start, offset: range.length) else { return nil }
        return input.textRange(from: start, to: end)
    }

    private func recoverDictation(_ session: DictationSession, finalized: String) {
        Self.logger.error("Dictation lost its native text range. Preserving recognized words through the draft.")
        dictationSession = nil
        isApplyingDictation = true
        defer { isApplyingDictation = false }
        parent.dictation?.commitNow()
        let recovered = dictatedText(session, finalized: finalized)
        lastModelText = recovered
        parent.text = recovered
        if let input {
            let selection = input.selectedRange
            input.typingAttributes = session.attributes
            input.text = recovered
            let location = min(max(selection.location, 0), recovered.utf16.count)
            input.selectedRange = NSRange(
                location: location, length: min(max(selection.length, 0), recovered.utf16.count - location)
            )
            parent.editor.update(from: input)
            input.invalidateIntrinsicContentSize()
        }
    }

    private func restoreSelection(_ selection: NSRange, replacing old: NSRange,
                                  with new: NSRange, caret: NSRange) {
        guard let input else { return }
        if selection.location >= old.location, NSMaxRange(selection) <= NSMaxRange(old) {
            input.selectedRange = caret
        } else if selection.location >= NSMaxRange(old) {
            input.selectedRange = NSRange(location: selection.location + new.length - old.length,
                                          length: selection.length)
        } else {
            input.selectedRange = selection
        }
    }

    private func neighbors(of session: DictationSession) -> (Character?, Character?) {
        let base = session.base as NSString
        let start = session.replaced.location
        let end = NSMaxRange(session.replaced)
        return (
            start > 0 ? base.substring(with: base.rangeOfComposedCharacterSequence(at: start - 1)).first : nil,
            end < base.length ? base.substring(with: base.rangeOfComposedCharacterSequence(at: end)).first : nil
        )
    }

    private func dictatedText(_ session: DictationSession, finalized: String) -> String {
        guard !finalized.isEmpty else { return session.base }
        let (previous, next) = neighbors(of: session)
        let (leading, trailing) = DictationTranscript.padding(for: finalized, after: previous, before: next)
        return (session.base as NSString).replacingCharacters(in: session.replaced, with: leading + finalized + trailing)
    }
}

final class ComposerTextView: UITextView {
    weak var coordinator: NativeComposerInput.Coordinator?
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

    override func insertText(_ text: String) {
        coordinator?.commitDictationBeforeEdit()
        super.insertText(text)
    }

    override func deleteBackward() {
        coordinator?.commitDictationBeforeEdit()
        super.deleteBackward()
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        coordinator?.commitDictationBeforeEdit()
        super.setMarkedText(markedText, selectedRange: selectedRange)
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

    func composerSizeThatFits(_ proposal: ProposedViewSize) -> CGSize? {
        guard let width = proposal.width, width > 0, let font else { return nil }
        let natural = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let insets = textContainerInset.top + textContainerInset.bottom
        let minimum = ceil(font.lineHeight + insets)
        let maximum = ceil(3 * font.lineHeight + insets)
        let available = max(minimum, min(maximum, proposal.height ?? maximum))
        isScrollEnabled = natural.height > available
        return CGSize(width: width, height: min(available, max(minimum, natural.height)))
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
