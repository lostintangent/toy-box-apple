import AppKit
import ChannelKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct ComposerMentionContext {
    let query: String
    let range: NSRange

    static func match(text: String, selection: NSRange) -> ComposerMentionContext? {
        guard selection.length == 0, selection.location >= 0, selection.location <= text.utf16.count else { return nil }
        let prefix = (text as NSString).substring(to: selection.location)
        guard let regex = try? NSRegularExpression(pattern: "(?:^|[^a-zA-Z0-9-])@([a-zA-Z0-9-]*)\\z"),
              let match = regex.firstMatch(in: prefix, range: NSRange(location: 0, length: prefix.utf16.count))
        else { return nil }
        let queryRange = match.range(at: 1)
        return .init(query: (prefix as NSString).substring(with: queryRange).lowercased(),
                     range: NSRange(location: queryRange.location - 1, length: queryRange.length + 1))
    }
}

struct ComposerFailureFeedback: Equatable {
    let id: String
    let message: String
}

struct ComposerFailureAnnouncements {
    private var announcedIDs: Set<String> = []

    mutating func receive(_ feedback: ComposerFailureFeedback, isEligible: Bool) -> Bool {
        guard isEligible else { return false }
        return announcedIDs.insert(feedback.id).inserted
    }
}

struct NativeComposerInput: NSViewRepresentable {
    @Binding var text: String
    /// The draft being edited. When it changes, such as on a channel switch, the same text view
    /// takes the new draft's text with a fresh caret and undo history.
    var document: ObjectIdentifier? = nil
    @Binding var height: CGFloat
    @Binding var focused: Bool
    @Binding var dragging: Bool
    var fontSize: CGFloat
    var focusRequest: UUID
    var agents: [ChannelAgent]
    var canManage: Bool
    var onSend: () -> Void
    var onFiles: ([URL]) -> Void
    var onImage: (ComposerImage) -> Void
    var onError: (String) -> Void
    var onCreate: (String) async throws -> ChannelAgent
    var onEdit: (ChannelAgent) -> Void
    var snapshot: WindowSnapshot? = nil
    var failureFeedback: ComposerFailureFeedback? = nil
    var dictation: ComposerDictation? = nil
    var allowsAgentManagement = true
    var isEditable = true
    var minimumHeight: CGFloat = 0
    var maximumLineCount = 3
    var onSendAndOpen: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil
    var onChooseChannel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let input = ComposerTextView()
        input.isRichText = false
        input.importsGraphics = false
        input.allowsUndo = true
        input.isAutomaticSpellingCorrectionEnabled = true
        input.isContinuousSpellCheckingEnabled = true
        input.isAutomaticTextReplacementEnabled = true
        input.isAutomaticQuoteSubstitutionEnabled = true
        input.isAutomaticDashSubstitutionEnabled = true
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.minSize = NSSize(width: 0, height: 44)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.textContainer?.lineFragmentPadding = 0
        input.textContainerInset = NSSize(width: 12, height: 12)
        input.drawsBackground = false
        input.textColor = .textColor
        input.insertionPointColor = .controlAccentColor
        input.setAccessibilityLabel("Channel message")
        input.setAccessibilityHelp("Return sends. Shift-Return starts a new line. Type @ to mention an agent.")
        input.delegate = context.coordinator
        input.coordinator = context.coordinator
        input.registerForDraggedTypes([.fileURL] + NSImage.imageTypes.map { .init($0) })
        scroll.documentView = input
        context.coordinator.input = input
        input.string = text
        configure(input)
        dictation?.target = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        // The outgoing draft keeps what was in flight for it, so leave before adopting the new parent.
        let isNewDocument = coordinator.document != document
        if isNewDocument { coordinator.leaveDocument() }
        coordinator.parent = self
        if let dictation, dictation.target !== coordinator { dictation.target = coordinator }
        guard let input = scroll.documentView as? ComposerTextView else { return }
        configure(input)
        if isNewDocument {
            coordinator.enterDocument(document, text: text)
        } else {
            coordinator.synchronizeModelText(text)
        }
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak input] in
                guard let input else { return }
                input.window?.makeFirstResponder(input)
            }
        }
        coordinator.measure()
        coordinator.announceSendFailure()
        if input.window?.firstResponder === input { coordinator.updateCompletion() }
        if let name = snapshot?.requestedState,
           ["composer-draft", "composer-mentions", "composer-mention-keys"].contains(name),
           coordinator.snapshotState != name, !text.isEmpty {
            coordinator.snapshotState = name
            DispatchQueue.main.async {
                input.window?.makeFirstResponder(input)
                input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
                coordinator.updateCompletion()
                if name.hasPrefix("composer-mention"), !coordinator.isCompletionVisible {
                    snapshot?.failState(name, message: "The native mention menu did not open.")
                } else if name == "composer-mention-keys" {
                    Task { await coordinator.verifySnapshotMentionKeys() }
                } else {
                    snapshot?.markStateReady(name)
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let dictation = coordinator.parent.dictation {
            // Words already spoken belong to this composer's draft, even as it goes away.
            dictation.commitNow()
            if dictation.target === coordinator { dictation.target = nil }
        }
        coordinator.dismissCompletion()
        (nsView.documentView as? ComposerTextView)?.delegate = nil
    }

    private func configure(_ input: NSTextView) {
        input.isEditable = isEditable
        guard input.font?.pointSize != fontSize
                || input.defaultParagraphStyle?.minimumLineHeight != fontSize * 20 / 14 else { return }
        let selection = input.selectedRange()
        input.font = .systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = fontSize * 20 / 14
        input.defaultParagraphStyle = paragraph
        input.typingAttributes = [.font: NSFont.systemFont(ofSize: fontSize),
                                  .foregroundColor: NSColor.textColor,
                                  .paragraphStyle: paragraph]
        input.setSelectedRange(selection)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerInput
        weak var input: ComposerTextView?
        var lastFocusRequest: UUID
        var snapshotState: String?
        var isCompletionVisible: Bool { popover?.isShown == true }
        private(set) var document: ObjectIdentifier?
        /// The composer's own undo stack, so Undo never reaches into a draft from another channel.
        let history = UndoManager()
        private var completion = MentionMenuModel()
        private var popover: NSPopover?
        private var mentionRange: NSRange?
        private var suppressedContext: String?
        private var lastModelText: String
        private var isApplyingModelText = false
        private static var failureAnnouncements = ComposerFailureAnnouncements()
        fileprivate var dictationSession: DictationSession? {
            didSet { input?.isDictating = dictationSession != nil }
        }
        fileprivate var isApplyingDictation = false
        var isDictating: Bool { dictationSession != nil }

        /// Dictated words show in the text storage as they arrive, without touching the undo stack.
        /// Committing restores the original text and inserts the final words as one undoable edit.
        fileprivate struct DictationSession {
            let base: String
            let replaced: NSRange
            let replacedText: String
            let attributes: [NSAttributedString.Key: Any]
            /// The shown words, or the original selection before any words arrive.
            var span: NSRange
        }

        init(parent: NativeComposerInput) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
            lastModelText = parent.text
            document = parent.document
            super.init()
            completion.onAccept = { [weak self] in self?.accept($0) }
            completion.onEdit = { [weak self] agent in
                self?.dismissCompletion()
                self?.parent.onEdit(agent)
            }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { history }

        /// Settles the outgoing draft while `parent` still writes to it. Composed and dictated
        /// words land there, and the mention menu closes.
        func leaveDocument() {
            if let input, input.hasMarkedText() {
                input.unmarkText()
                input.inputContext?.discardMarkedText()
            }
            parent.dictation?.leaveDraft()
            if let input, input.string != lastModelText {
                lastModelText = input.string
                parent.text = input.string
            }
            dismissCompletion()
            suppressedContext = nil
            completion.creatingID = nil
            completion.error = nil
        }

        /// Shows another draft the way a new text view would, with nothing to undo and the caret
        /// at its end, scrolled into view.
        func enterDocument(_ document: ObjectIdentifier?, text: String) {
            self.document = document
            lastModelText = text
            guard let input else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: input.font ?? NSFont.systemFont(ofSize: parent.fontSize),
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: input.defaultParagraphStyle ?? NSParagraphStyle.default
            ]
            isApplyingModelText = true
            input.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            isApplyingModelText = false
            input.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            input.typingAttributes = attributes
            history.removeAllActions()
            input.scroll(.zero)
            measure()
            input.scrollRangeToVisible(input.selectedRange())
            NSAccessibility.post(element: input, notification: .valueChanged)
        }

        func synchronizeModelText(_ text: String) {
            guard let input, text != lastModelText, !input.hasMarkedText() else { return }
            if dictationSession != nil { abandonDictation() }
            lastModelText = text
            guard input.string != text else { return }
            let oldLength = input.string.utf16.count
            let selection = input.selectedRange()
            isApplyingModelText = true
            input.breakUndoCoalescing()
            input.insertText(text, replacementRange: NSRange(location: 0, length: oldLength))
            input.breakUndoCoalescing()
            let location = selection.length == 0 && selection.location == oldLength
                ? text.utf16.count : min(selection.location, text.utf16.count)
            input.setSelectedRange(NSRange(location: location,
                                           length: min(selection.length, text.utf16.count - location)))
            isApplyingModelText = false
        }

        func textDidChange(_ notification: Notification) {
            guard let input, !isApplyingModelText else { return }
            lastModelText = input.string
            parent.text = input.string
            measure()
            updateCompletion()
        }

        func announceSendFailure() {
            guard parent.snapshot == nil, let feedback = parent.failureFeedback,
                  let input, let window = input.window,
                  Self.failureAnnouncements.receive(
                    feedback, isEligible: window.isKeyWindow && window.isVisible && !window.isMiniaturized
                  ) else { return }
            NSAccessibility.post(element: input, notification: .announcementRequested,
                                 userInfo: [.announcement: feedback.message,
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }

        func verifySnapshotMentionKeys() async {
            let name = "composer-mention-keys"
            guard let input, let snapshot = parent.snapshot else { return }
            do {
                try await Task.sleep(for: .milliseconds(80))
                input.breakUndoCoalescing()
                input.undoManager?.removeAllActions()
                func key(_ code: UInt16, _ characters: String) -> NSEvent? {
                    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: input.window?.windowNumber ?? 0, context: nil,
                                     characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: code)
                }
                guard isCompletionVisible, completion.items[safe: 1]?.name == "Lead",
                      let down = key(125, "\u{f701}"), let tab = key(48, "\t"),
                      handle(down), handle(tab), input.string == "@lead ", parent.text == "@lead ",
                      input.selectedRange() == NSRange(location: 6, length: 0) else {
                    snapshot.failState(name, message: "Down/Tab did not accept Lead with a trailing space and caret.")
                    return
                }
                try await Task.sleep(for: .milliseconds(80))
                guard let undo = input.undoManager, undo.canUndo else {
                    snapshot.failState(name, message: "Mention acceptance was not undoable.")
                    return
                }
                undo.undo()
                guard input.string == "@", parent.text == "@" else {
                    snapshot.failState(name, message: "Undo did not restore the original mention query.")
                    return
                }
                input.setSelectedRange(NSRange(location: 1, length: 0))
                updateCompletion()
                guard isCompletionVisible, let escape = key(53, "\u{1b}"), handle(escape) else {
                    snapshot.failState(name, message: "The restored mention menu did not consume Escape.")
                    return
                }
                updateCompletion()
                guard !isCompletionVisible, input.string == "@" else {
                    snapshot.failState(name, message: "Escape reopened the menu or destroyed the query.")
                    return
                }
                snapshot.markStateReady(name)
            } catch {
                snapshot.failState(name, message: error.localizedDescription)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) { updateCompletion() }

        func measure() {
            guard let input, let container = input.textContainer, let layout = input.layoutManager else { return }
            layout.ensureLayout(for: container)
            let line = parent.fontSize * 20 / 14
            let height = max(parent.minimumHeight,
                             max(line, min(line * CGFloat(parent.maximumLineCount),
                                           layout.usedRect(for: container).height)) + 24)
            if abs(parent.height - height) > 0.5 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = height }
            }
        }

        func handle(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if dictationSession != nil, let dictation = parent.dictation {
                if event.keyCode == 53 {
                    Task { await dictation.stop(.escape) }
                    return true
                }
                if [36, 76].contains(event.keyCode), !modifiers.contains(.shift),
                   modifiers.isDisjoint(with: [.option, .control]) {
                    send(modifiers: modifiers)
                    return true
                }
                // Typing takes over from dictation, keeping every word already shown.
                dictation.commitNow()
            }
            guard let input, !input.hasMarkedText() else { return false }
            if event.keyCode == 37, modifiers == .command, let choose = parent.onChooseChannel {
                choose()
                return true
            }
            if popover?.isShown == true {
                switch event.keyCode {
                case 125:
                    moveSelection(by: 1)
                    return true
                case 126:
                    moveSelection(by: -1)
                    return true
                case 36, 76, 48:
                    // Like the pane, Shift passes through to a new line or the previous key view, and
                    // Option-Tab stays a literal tab.
                    guard !modifiers.contains(.shift), event.keyCode != 48 || !modifiers.contains(.option)
                    else { break }
                    if let item = completion.items[safe: completion.selected] { accept(item) }
                    return true
                case 53:
                    suppressedContext = contextSignature
                    dismissCompletion()
                    return true
                default: break
                }
            }
            if [36, 76].contains(event.keyCode), !modifiers.contains(.shift),
               modifiers.isDisjoint(with: [.option, .control]) {
                send(modifiers: modifiers)
                return true
            }
            if event.keyCode == 53, let escape = parent.onEscape {
                escape()
                return true
            }
            return false
        }

        private func send(modifiers: NSEvent.ModifierFlags) {
            guard parent.isEditable else { return }
            if modifiers.contains(.command), let sendAndOpen = parent.onSendAndOpen { sendAndOpen() }
            else { parent.onSend() }
        }

        private func moveSelection(by offset: Int) {
            let selected = max(0, min(completion.selected + offset, completion.items.count - 1))
            guard selected != completion.selected, let item = completion.items[safe: selected] else { return }
            completion.selected = selected
            guard let input else { return }
            NSAccessibility.post(
                element: input, notification: .announcementRequested,
                userInfo: [.announcement: "\(item.isCreate ? "Create " : "")\(item.name). \(item.detail)",
                           .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
        }

        var contextSignature: String {
            guard let input else { return "" }
            return "\(input.selectedRange().location):\(input.string)"
        }

        func updateCompletion() {
            guard let input, parent.isEditable, dictationSession == nil, input.window?.firstResponder === input, !input.hasMarkedText(),
                  input.selectedRange().length == 0, suppressedContext != contextSignature else {
                dismissCompletion()
                return
            }
            guard let context = ComposerMentionContext.match(text: input.string, selection: input.selectedRange())
            else { dismissCompletion(); return }
            mentionRange = context.range
            let items = MentionChoice.items(query: context.query, agents: parent.agents,
                                            allowsCreation: parent.allowsAgentManagement)
            guard !items.isEmpty else { dismissCompletion(); return }
            if completion.items.map(\.id) != items.map(\.id) { completion.selected = 0 }
            if completion.items != items { completion.items = items }
            let canManage = parent.canManage && parent.allowsAgentManagement
            if completion.canManage != canManage { completion.canManage = canManage }
            completion.showsManagement = parent.allowsAgentManagement
            if popover == nil {
                let popover = NSPopover()
                popover.behavior = .semitransient
                popover.animates = false
                popover.contentViewController = NSHostingController(rootView: MentionCompletionMenu(model: completion))
                self.popover = popover
            }
            let caret = input.firstRect(forCharacterRange: input.selectedRange(), actualRange: nil)
            guard let window = input.window else { return }
            let rect = input.convert(window.convertFromScreen(caret), from: nil)
            let errorHeight: CGFloat = completion.error == nil ? 0 : 64
            let size = NSSize(width: 300, height: min(CGFloat(items.count) * 50 + 12 + errorHeight, 320))
            if popover?.contentSize != size { popover?.contentSize = size }
            if popover?.isShown == true {
                if popover?.positioningRect != rect { popover?.positioningRect = rect }
            } else {
                popover?.show(relativeTo: rect, of: input, preferredEdge: .minY)
            }
        }

        private func accept(_ item: MentionChoice) {
            guard let input, let range = mentionRange, completion.creatingID == nil else { return }
            if item.isCreate {
                guard parent.canManage else { return }
                let originalText = input.string
                let originalSelection = input.selectedRange()
                let origin = parent
                let document = document
                completion.creatingID = item.id
                completion.error = nil
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let member = try await origin.onCreate(item.name)
                        // The member joined the channel it was created for. Its draft has gone.
                        guard self.document == document else { return }
                        completion.creatingID = nil
                        if let input = self.input, input.string == originalText,
                           input.selectedRange() == originalSelection, !input.hasMarkedText() {
                            dismissCompletion()
                            insertMention("@\(agentHandleFromName(member.name))", replacing: range)
                        } else if let input = self.input {
                            NSAccessibility.post(
                                element: input, notification: .announcementRequested,
                                userInfo: [.announcement: "\(member.name) was created. Mention @\(agentHandleFromName(member.name)) to address them.",
                                           .priority: NSAccessibilityPriorityLevel.medium.rawValue]
                            )
                        }
                    } catch {
                        guard self.document == document else {
                            origin.onError(error.localizedDescription)
                            return
                        }
                        completion.creatingID = nil
                        completion.error = error.localizedDescription
                        if popover?.isShown != true { parent.onError(error.localizedDescription) }
                        updateCompletion()
                    }
                }
                return
            }
            dismissCompletion()
            insertMention(item.handle, replacing: range)
        }

        private func insertMention(_ handle: String, replacing range: NSRange) {
            guard let input else { return }
            input.breakUndoCoalescing()
            input.insertText("\(handle) ", replacementRange: range)
            input.breakUndoCoalescing()
            input.window?.makeFirstResponder(input)
        }

        func dismissCompletion() {
            popover?.close()
            mentionRange = nil
        }

        func acceptPasteboard(_ pasteboard: NSPasteboard) -> Bool {
            guard parent.isEditable else { return false }
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true
            ]) as? [URL], !urls.isEmpty {
                parent.onFiles(urls)
                return true
            }
            for type in pasteboard.types ?? [] {
                guard let uniform = UTType(type.rawValue), uniform.conforms(to: .image),
                      let data = pasteboard.data(forType: type) else { continue }
                let mime = uniform.preferredMIMEType ?? "image/png"
                parent.onImage(.init(name: "Pasted image.\(uniform.preferredFilenameExtension ?? "png")",
                                     mimeType: mime, data: data))
                return true
            }
            return false
        }
    }
}

extension NativeComposerInput.Coordinator: DictationTextTarget {
    var isInKeyWindow: Bool { input?.window?.isKeyWindow == true }

    func beginDictation() -> Bool {
        guard let input, let window = input.window, input.isEditable else { return false }
        if dictationSession != nil { return true }
        if window.firstResponder !== input, !window.makeFirstResponder(input) { return false }
        if input.hasMarkedText() {
            input.unmarkText()
            input.inputContext?.discardMarkedText()
        }
        dismissCompletion()
        let range = input.selectedRange()
        var attributes = input.typingAttributes
        attributes[.foregroundColor] = NSColor.textColor
        dictationSession = .init(base: input.string, replaced: range,
                                 replacedText: (input.string as NSString).substring(with: range),
                                 attributes: attributes, span: range)
        return true
    }

    func showDictation(_ transcript: DictationTranscript) {
        guard let input, let storage = input.textStorage, var session = dictationSession else { return }
        let (previous, next) = Self.neighbors(of: session)
        let visible = transcript.visible
        let display = NSMutableAttributedString()
        var trailingLength = 0
        if visible.isEmpty {
            display.append(NSAttributedString(string: session.replacedText, attributes: session.attributes))
        } else {
            let (leading, trailing) = DictationTranscript.padding(for: visible, after: previous, before: next)
            var tentative = session.attributes
            tentative[.foregroundColor] = NSColor.secondaryLabelColor
            display.append(NSAttributedString(string: leading + transcript.finalized, attributes: session.attributes))
            display.append(NSAttributedString(string: String(visible.dropFirst(transcript.finalized.count)) + trailing,
                                              attributes: tentative))
            trailingLength = trailing.utf16.count
        }
        let selection = input.selectedRange()
        let old = session.span
        isApplyingDictation = true
        storage.replaceCharacters(in: old, with: display)
        isApplyingDictation = false
        session.span = NSRange(location: old.location, length: display.length)
        dictationSession = session
        if selection.location >= old.location, NSMaxRange(selection) <= NSMaxRange(old) {
            input.setSelectedRange(visible.isEmpty ? session.span
                                   : NSRange(location: NSMaxRange(session.span) - trailingLength, length: 0))
        } else if selection.location >= NSMaxRange(old) {
            input.setSelectedRange(NSRange(location: selection.location + session.span.length - old.length,
                                           length: selection.length))
        } else {
            input.setSelectedRange(selection)
        }
        input.typingAttributes = session.attributes
        let model = Self.dictatedText(session, finalized: transcript.finalized)
        if model != lastModelText {
            lastModelText = model
            parent.text = model
        }
        measure()
        input.scrollRangeToVisible(input.selectedRange())
        NSAccessibility.post(element: input, notification: .valueChanged)
    }

    func endDictation(_ finalized: String) {
        guard let session = dictationSession else { return }
        dictationSession = nil
        guard let input, let storage = input.textStorage else {
            parent.text = Self.dictatedText(session, finalized: finalized)
            return
        }
        let selection = input.selectedRange()
        isApplyingDictation = true
        storage.replaceCharacters(in: session.span,
                                  with: NSAttributedString(string: session.replacedText, attributes: session.attributes))
        isApplyingDictation = false
        input.typingAttributes = session.attributes
        let (previous, next) = Self.neighbors(of: session)
        let (leading, trailing) = DictationTranscript.padding(for: finalized, after: previous, before: next)
        let words = finalized.isEmpty ? session.replacedText : leading + finalized + trailing
        if !finalized.isEmpty {
            // One undo step for the whole session. A top-level group keeps a key typed in this same
            // event, which commits the session, out of the dictation's undo step.
            input.breakUndoCoalescing()
            let undo = input.undoManager
            let ownsGroup = undo?.groupingLevel == 0 && undo?.groupsByEvent == true
            if ownsGroup { undo?.groupsByEvent = false }
            undo?.beginUndoGrouping()
            input.insertText(words, replacementRange: session.replaced)
            undo?.setActionName("Dictation")
            undo?.endUndoGrouping()
            if ownsGroup { undo?.groupsByEvent = true }
            input.breakUndoCoalescing()
        }
        let span = session.span
        let length = words.utf16.count
        if selection.location >= span.location, NSMaxRange(selection) <= NSMaxRange(span) {
            input.setSelectedRange(finalized.isEmpty ? session.replaced
                                   : NSRange(location: session.replaced.location + length - trailing.utf16.count, length: 0))
        } else if selection.location >= NSMaxRange(span) {
            input.setSelectedRange(NSRange(location: selection.location + length - span.length, length: selection.length))
        } else {
            input.setSelectedRange(selection)
        }
        lastModelText = input.string
        if parent.text != input.string { parent.text = input.string }
        measure()
    }

    /// Commits the session before an edit that didn't come from a key press, such as Paste or a
    /// spelling correction. Committing keeps the shown text identical, so the edit's range holds.
    func commitDictationBeforeEdit() {
        guard dictationSession != nil, !isApplyingDictation,
              input?.undoManager?.isUndoing != true, input?.undoManager?.isRedoing != true else { return }
        parent.dictation?.commitNow()
    }

    /// Drops the shown words when the draft is replaced from outside the text view.
    fileprivate func abandonDictation() {
        guard let session = dictationSession, let storage = input?.textStorage else { return }
        dictationSession = nil
        isApplyingDictation = true
        storage.replaceCharacters(in: session.span,
                                  with: NSAttributedString(string: session.replacedText, attributes: session.attributes))
        isApplyingDictation = false
        input?.typingAttributes = session.attributes
        if let dictation = parent.dictation { Task { dictation.commitNow() } }
    }

    private static func neighbors(of session: DictationSession) -> (Character?, Character?) {
        let base = session.base as NSString
        let start = session.replaced.location
        let end = NSMaxRange(session.replaced)
        let previous = start > 0 ? base.substring(with: base.rangeOfComposedCharacterSequence(at: start - 1)).first : nil
        let next = end < base.length ? base.substring(with: base.rangeOfComposedCharacterSequence(at: end)).first : nil
        return (previous, next)
    }

    /// The draft with the finalized words in place of the original selection.
    private static func dictatedText(_ session: DictationSession, finalized: String) -> String {
        guard !finalized.isEmpty else { return session.base }
        let (previous, next) = neighbors(of: session)
        let (leading, trailing) = DictationTranscript.padding(for: finalized, after: previous, before: next)
        return (session.base as NSString).replacingCharacters(in: session.replaced, with: leading + finalized + trailing)
    }
}

@MainActor final class ComposerTextView: NSTextView {
    weak var coordinator: NativeComposerInput.Coordinator?
    /// Mirrors the coordinator's dictation session for `responds(to:)`, which AppKit may call from any context.
    nonisolated(unsafe) var isDictating = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            center.addObserver(self, selector: #selector(windowBecameKey),
                               name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowResignedKey),
                               name: NSWindow.didResignKeyNotification, object: window)
            coordinator?.announceSendFailure()
        }
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        coordinator?.announceSendFailure()
    }

    @objc private func windowResignedKey(_ notification: Notification) {
        coordinator?.parent.dictation?.windowResignedKey()
    }

    override func keyDown(with event: NSEvent) {
        if coordinator?.handle(event) == true { return }
        super.keyDown(with: event)
    }

    // Tab and Shift-Tab leave the composer like a browser textarea. Option-Tab is bound to
    // insertTabIgnoringFieldEditor:, so it still inserts a tab.
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Shortcuts such as Command-Z or Command-A act on committed words. Return and Escape keep
        // their dictation meanings in keyDown.
        if coordinator?.isDictating == true, window?.firstResponder === self, ![36, 76, 53].contains(event.keyCode) {
            coordinator?.parent.dictation?.commitNow()
        }
        return super.performKeyEquivalent(with: event)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        coordinator?.commitDictationBeforeEdit()
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        coordinator?.commitDictationBeforeEdit()
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    /// While dictating, Edit > Undo first commits the session, so it undoes the dictated words.
    @objc(undo:) func undoDictation(_ sender: Any?) {
        coordinator?.parent.dictation?.commitNow()
        undoManager?.undo()
    }

    @objc(redo:) func redoDuringDictation(_ sender: Any?) {}

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(undoDictation(_:)) || selector == #selector(redoDuringDictation(_:)) {
            return isDictating
        }
        return super.responds(to: selector)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoDictation(_:)) {
            let hasWords = coordinator?.parent.dictation?.hasWords == true
            menuItem.title = hasWords ? "Undo Dictation" : (undoManager?.undoMenuItemTitle ?? "Undo")
            return hasWords || undoManager?.canUndo == true
        }
        if menuItem.action == #selector(redoDuringDictation(_:)) {
            menuItem.title = "Redo"
            return false
        }
        return super.validateMenuItem(menuItem)
    }

    override func paste(_ sender: Any?) {
        coordinator?.parent.dictation?.commitNow()
        if coordinator?.acceptPasteboard(.general) == true { return }
        super.pasteAsPlainText(sender)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { coordinator?.parent.focused = true }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            coordinator?.parent.focused = false
            coordinator?.dismissCompletion()
        }
        return result
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isEditable, coordinator?.parent.isEditable != false else { return [] }
        coordinator?.parent.dragging = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        coordinator?.parent.dragging = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        coordinator?.parent.dragging = false
        let accepted = coordinator?.acceptPasteboard(sender.draggingPasteboard) == true
        if !accepted { coordinator?.parent.onError("Drop an image file to attach it to this message.") }
        return accepted
    }
}

struct MentionChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let handle: String
    var agent: ChannelAgent?
    var isCreate = false
    var isMember = false

    static func items(query: String, agents: [ChannelAgent], allowsCreation: Bool = true) -> [MentionChoice] {
        var items: [MentionChoice] = []
        if query.isEmpty || "everyone".contains(query) {
            items.append(.init(id: "everyone", name: "Everyone", detail: "Notify everyone in the channel",
                               handle: "@everyone"))
        }
        for agent in Array(agents.prefix(1)) + agents.dropFirst().sorted(by: {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }) where agent.deleted != true && agentMatchesMentionQuery(agent, query: query) {
            items.append(.init(id: agent.id, name: agent.name, detail: agent.role ?? "Onboarding",
                               handle: "@\(agentHandleFromName(agent.name))", agent: agent,
                               isMember: agent.id != agents.first?.id))
        }
        let words = query.split(separator: "-")
        if allowsCreation, !words.isEmpty && !items.contains(where: { $0.handle == "@\(query)" }) {
            let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            items.append(.init(id: "create-\(query)", name: name, detail: "Creates and starts a new agent",
                               handle: "@\(query)", isCreate: true))
        }
        return items
    }
}

@MainActor @Observable private final class MentionMenuModel {
    var items: [MentionChoice] = []
    var selected = 0
    var canManage = false
    var showsManagement = true
    var creatingID: String?
    var error: String?
    @ObservationIgnored var onAccept: ((MentionChoice) -> Void)?
    @ObservationIgnored var onEdit: ((ChannelAgent) -> Void)?
}

private struct MentionCompletionMenu: View {
    let model: MentionMenuModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Label {
                    Text(error).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                }
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .accessibilityLabel("Creation failed: \(error)")
                Divider()
            }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            choiceRow(item, index: index).id(item.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selected) { _, selected in
                    if let item = model.items[safe: selected] { reader.scrollTo(item.id) }
                }
            }
        }
        .frame(width: 300)
        .frame(maxHeight: 320)
    }

    private func choiceRow(_ item: MentionChoice, index: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                model.onAccept?(item)
            } label: {
                HStack(spacing: 8) {
                    if let agent = item.agent {
                        AgentAvatarView(agent: agent, size: 24)
                    } else if model.creatingID == item.id {
                        ProgressView().controlSize(.small).frame(width: 24, height: 24)
                    } else {
                        Image(systemName: item.isCreate ? "person.badge.plus" : "person.3")
                            .frame(width: 24, height: 24)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(item)).font(.system(size: 13, weight: .medium))
                        Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.creatingID != nil || (item.isCreate && !model.canManage))
            .accessibilityAddTraits(index == model.selected ? .isSelected : [])
            if model.showsManagement, let agent = item.agent, item.isMember {
                Button("Edit…") { model.onEdit?(agent) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(!model.canManage || model.creatingID != nil)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 48)
        .background(index == model.selected ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func title(_ item: MentionChoice) -> String {
        if model.creatingID == item.id { return "Creating \(item.name)..." }
        return item.isCreate ? "Create \(item.name)" : item.name
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
