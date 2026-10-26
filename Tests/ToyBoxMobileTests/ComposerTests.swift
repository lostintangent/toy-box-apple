import AVFoundation
@testable import ChannelClient
import ChannelKit
import SwiftUI
import Testing
import ToyBoxUI
import UIKit
import UniformTypeIdentifiers
@testable import ToyBoxMobile

@MainActor @Suite(.timeLimit(.minutes(1)))
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

    @Test func readerFocusReturnsOnlyOnceToItsPreviouslyOwnedUncoveredConversation() {
        var focus = ComposerReaderFocus()
        focus.cover(ownsFocus: true)
        focus.cover(ownsFocus: false)
        #expect(focus.isCovered)
        var restored = focus.uncover(canRestoreFocus: true)
        #expect(restored)
        #expect(!focus.isCovered)
        restored = focus.uncover(canRestoreFocus: true)
        #expect(!restored)

        focus.cover(ownsFocus: false)
        restored = focus.uncover(canRestoreFocus: true)
        #expect(!restored)
        focus.cover(ownsFocus: true)
        restored = focus.uncover(canRestoreFocus: false)
        #expect(!restored)
        restored = focus.uncover(canRestoreFocus: true)
        #expect(!restored)
    }

    @Test func dismantlingTheCoveredEditorCancelsItsFocusReturn() {
        var focus = ComposerReaderFocus()
        focus.cover(ownsFocus: true)
        focus.cancelRestoration()
        #expect(focus.isCovered)
        let restored = focus.uncover(canRestoreFocus: true)
        #expect(!restored)
    }

    @Test func readerCoverageRetainsTheNativeEditorTextSelectionAndUndo() throws {
        var text = ""
        let editor = ComposerEditorState()
        let input = NativeComposerInput(
            text: Binding(get: { text }, set: { text = $0 }), editor: editor,
            onSend: {}, onCompletionKey: { _ in false }, onPasteImages: { _ in }
        )
        let coordinator = NativeComposerInput.Coordinator(parent: input)
        let view = ComposerTextView()
        editor.textView = view
        view.delegate = coordinator
        view.insertText("Keep this draft")
        view.selectedRange = NSRange(location: 2, length: 3)
        coordinator.textViewDidChangeSelection(view)
        let undo = try #require(view.undoManager)
        #expect(undo.canUndo)

        editor.setReaderCovered(true, canRestoreFocus: false)
        #expect(editor.isReaderCovered)
        #expect(!view.isEditable)
        #expect(editor.textView === view)
        #expect(text == "Keep this draft")
        #expect(view.text == text)
        #expect(editor.selection == NSRange(location: 2, length: 3))
        #expect(view.selectedRange == editor.selection)
        #expect(!view.canPerformAction(#selector(ComposerTextView.hardwareReturn), withSender: nil))

        editor.setReaderCovered(false, canRestoreFocus: true)
        #expect(!editor.isReaderCovered)
        #expect(view.isEditable)
        #expect(editor.textView === view)
        #expect(editor.selection == NSRange(location: 2, length: 3))
        #expect(undo.canUndo)
        undo.undo()
        #expect(text.isEmpty)
        #expect(view.text == text)

        editor.setReaderCovered(true, canRestoreFocus: false)
        editor.setEditingAllowed(false)
        editor.setReaderCovered(false, canRestoreFocus: true)
        #expect(!view.isEditable)
    }

    @Test func theNativeDraftUsesOpaqueAdaptiveLabelInk() throws {
        let input = ComposerTextView()
        input.text = "Readable draft"
        let ink = try #require(input.textColor)
        #expect(input.text == "Readable draft")
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let resolved = ink.resolvedColor(with: traits)
            #expect(resolved == UIColor.label.resolvedColor(with: traits))
            #expect(resolved.cgColor.alpha == 1)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func placeholderUsesReadableSecondaryInkEvenUnderAnInheritedPrimaryStyle(
        scheme: ColorScheme, listening: Bool
    ) throws {
        let renderer = ImageRenderer(content: ComposerPlaceholder(isListening: listening)
            .foregroundStyle(Color.primary)
            .environment(\.colorScheme, scheme)
            .dynamicTypeSize(.large))
        renderer.scale = 1
        let image = try #require(renderer.uiImage?.cgImage)
        let pixels = try renderedPixels(image)
        let strongest = try #require(stride(from: 0, to: pixels.count, by: 4).max {
            pixels[$0 + 3] < pixels[$1 + 3]
        })
        #expect(pixels[strongest + 3] >= 250)
        let expected = scheme == .dark ? [174, 174, 178] : [99, 99, 102]
        for component in 0..<3 {
            #expect(abs(Int(pixels[strongest + component]) - expected[component]) <= 3)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark], [DynamicTypeSize.large, .accessibility5])
    func audienceCapsuleIsSeparateFromIts44PointRowAndGrowsWithText(
        scheme: ColorScheme, size: DynamicTypeSize
    ) throws {
        let lead = ChannelAgent.lead(id: "test", profile: .init(
            name: "Lead", role: "Coordinator", avatar: .init(mark: "M4 12H20", color: "#123456")
        ))
        let renderer = ImageRenderer(content:
            ComposerAudienceView(text: "", agents: [lead], acknowledgesRequest: false)
                .environment(\.colorScheme, scheme)
                .dynamicTypeSize(size))
        renderer.scale = 1
        renderer.proposedSize = .init(width: 260, height: nil)
        let image = try #require(renderer.uiImage?.cgImage)
        #expect(image.height >= 44)
        let pixels = try renderedPixels(image)
        let center = image.width / 2
        let filledRows = (0..<image.height).filter { pixels[($0 * image.width + center) * 4 + 3] > 0 }
        let first = try #require(filledRows.first)
        let last = try #require(filledRows.last)
        #expect(last - first + 1 >= 24, "Audience has a visible badge, not only bare text")
        if size == .large {
            #expect(image.height == 44)
            #expect(last - first + 1 == 24)
            #expect(first >= 9 && image.height - 1 - last >= 9)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark], [DynamicTypeSize.large, .accessibility5])
    func hintFitsAtItsNativeFontWithoutEllipsis(scheme: ColorScheme, size: DynamicTypeSize) throws {
        let actual = try render(ComposerPlaceholder(isListening: false)
            .frame(width: 340, alignment: .leading)
            .environment(\.colorScheme, scheme).dynamicTypeSize(size), width: 340)
        let expected = try render(Text(size == .accessibility5 ? "Message" : "Message your team")
            .font(.body).foregroundStyle(ChannelInk.secondary)
            .frame(width: 340, alignment: .leading)
            .environment(\.colorScheme, scheme).dynamicTypeSize(size), width: 340)
        #expect(actual.width == expected.width)
        #expect(actual.height == expected.height)
        #expect(try renderedPixels(actual) == renderedPixels(expected))
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func largestTypeContextUsesSeparateFullHeightRowsWhenBothLabelsDoNotFit(scheme: ColorScheme) throws {
        let lead = ChannelAgent.lead(id: "test", profile: .init(
            name: "Lead", role: "Coordinator", avatar: .init(mark: "M4 12H20", color: "#123456")
        ))
        let audience = ComposerAudienceView(text: "", agents: [lead], acknowledgesRequest: true)
        let request = ComposerRequestLabel(wraps: true).font(.footnote)
        for width: CGFloat in [220, 340, 426] {
            let context = try render(ComposerContextLayout { audience; request }
                .environment(\.colorScheme, scheme).dynamicTypeSize(.accessibility5), width: width)
            let reference = try render(VStack(alignment: .leading, spacing: 4) {
                audience
                request
            }.environment(\.colorScheme, scheme).dynamicTypeSize(.accessibility5), width: width)
            #expect(abs(context.height - reference.height) <= 1,
                    "The complete wrapping request and audience each retain their measured row")
            #expect(context.width <= Int(width))
        }
        let wrapped = try render(request.dynamicTypeSize(.accessibility5), width: 220)
        let unwrapped = try render(request.dynamicTypeSize(.accessibility5))
        #expect(wrapped.height > unwrapped.height, "The full request wraps rather than truncating")
        let wide = try render(ComposerContextLayout { audience; request }
            .dynamicTypeSize(.accessibility5), width: 720)
        let inline = try render(HStack(spacing: 4) { audience; request }
            .dynamicTypeSize(.accessibility5), width: 720)
        #expect(wide.height == inline.height, "Fitting context stays on one row")
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility5])
    func attachmentGlyphStays17PointsInsideIts44PointTarget(size: DynamicTypeSize) throws {
        let image = try render(ComposerAttachmentLabel().dynamicTypeSize(size))
        #expect(image.width == 44 && image.height == 44)
        let pixels = try renderedPixels(image)
        let occupiedRows = (0..<image.height).filter { y in
            (0..<image.width).contains { pixels[(y * image.width + $0) * 4 + 3] > 0 }
        }
        let first = try #require(occupiedRows.first)
        let last = try #require(occupiedRows.last)
        #expect(last - first + 1 <= 22, "A symbol image may extend slightly beyond its 17-point font")
        #expect(first >= 10 && last < 34)
    }

    @Test func upperContextCompressesBeforeTheNativeEditorAndActionRow() throws {
        let editor = ComposerEditorState()
        var text = "A draft"
        func content(height: CGFloat) -> some View {
            VStack(spacing: 0) {
                ComposerUpperRegion {
                    ComposerRequestLabel(wraps: true).font(.footnote)
                    Text("Images are still loading. You can keep editing your message.")
                        .font(.body)
                }
                NativeComposerInput(
                    text: Binding(get: { text }, set: { text = $0 }), editor: editor,
                    onSend: {}, onCompletionKey: { _ in false }, onPasteImages: { _ in }
                ).layoutPriority(1)
                HStack {
                    ComposerAttachmentLabel()
                    Spacer()
                    Image(systemName: "arrow.up").frame(width: 44, height: 44)
                }.fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 340, height: height)
            .dynamicTypeSize(.accessibility5)
        }
        let host = UIHostingController(rootView: content(height: 210))
        host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        host.view.frame = CGRect(x: 0, y: 0, width: 340, height: 210)
        host.view.layoutIfNeeded()
        #expect(editor.textView == nil, "A detached hosting view has not mounted the native editor")
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let input = try #require(editor.textView)
        editor.selection = NSRange(location: 3, length: 0)
        input.selectedRange = NSRange(location: 3, length: 0)
        let scroll = try #require(descendants(of: host.view).compactMap { $0 as? UIScrollView }
            .first { !($0 is UITextView) })
        let oneLine = ceil(try #require(input.font).lineHeight + NativeComposerInput.textInsets.top)
        let inputFrame = input.convert(input.bounds, to: host.view)
        #expect(inputFrame.height >= oneLine)
        #expect(inputFrame.maxY <= host.view.bounds.height - 44)
        #expect(scroll.bounds.height > 0 && scroll.bounds.height < scroll.contentSize.height)
        host.rootView = content(height: 600)
        window.frame.size.height = 600
        window.setNeedsLayout()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(editor.textView === input)
        #expect(input.text == "A draft")
        #expect(input.selectedRange == NSRange(location: 3, length: 0))
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func render<Content: View>(_ content: Content, width: CGFloat? = nil) throws -> CGImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = .init(width: width, height: nil)
        return try #require(renderer.uiImage?.cgImage)
    }

    private func renderedPixels(_ image: CGImage) throws -> [UInt8] {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(
                x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return pixels
    }

    @Test func editorFitsOneThroughThreeMeasuredLinesWithoutChangingItsTextOrCaret() throws {
        let largest = UIFont.preferredFont(forTextStyle: .body, compatibleWith:
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        for pointSize: CGFloat in [17, 40, largest.pointSize] {
            let view = ComposerTextView()
            let font = UIFont.systemFont(ofSize: pointSize)
            view.font = font
            view.textContainerInset = NativeComposerInput.textInsets
            view.text = "One\nTwo\nThree\nFour"
            view.selectedRange = NSRange(location: 2, length: 0)
            let verticalInset = NativeComposerInput.textInsets.top + NativeComposerInput.textInsets.bottom
            let oneLine = ceil(font.lineHeight + verticalInset)
            let threeLines = ceil(3 * font.lineHeight + verticalInset)
            let full = try #require(view.composerSizeThatFits(.init(width: 320, height: nil)))
            #expect(full.height == threeLines)
            #expect(view.isScrollEnabled)
            let compact = try #require(view.composerSizeThatFits(.init(width: 320, height: oneLine)))
            #expect(compact.height == oneLine)
            #expect(view.isScrollEnabled)
            let smaller = try #require(view.composerSizeThatFits(.init(width: 320, height: 0)))
            #expect(smaller.height == oneLine)
            #expect(view.text == "One\nTwo\nThree\nFour")
            #expect(view.selectedRange == NSRange(location: 2, length: 0))
            view.text = "One"
            let short = try #require(view.composerSizeThatFits(.init(width: 320, height: nil)))
            #expect(short.height == oneLine)
            #expect(!view.isScrollEnabled)
        }
    }

    @Test func tentativeDictationStaysOutOfTheBindingAndFinalWordsFormOneUndoStep() throws {
        var text = "Hello old world"
        let editor = ComposerEditorState()
        let input = NativeComposerInput(
            text: Binding(get: { text }, set: { text = $0 }), editor: editor,
            onSend: {}, onCompletionKey: { _ in false }, onPasteImages: { _ in }
        )
        let coordinator = NativeComposerInput.Coordinator(parent: input)
        let view = ComposerTextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.delegate = coordinator
        view.coordinator = coordinator
        coordinator.input = view
        editor.textView = view
        view.text = text
        view.selectedRange = NSRange(location: 6, length: 3)
        coordinator.anchorDictation()
        var transcript = DictationTranscript()
        transcript.receive("new", isFinal: true)
        transcript.receive("words", isFinal: false)
        coordinator.showDictation(transcript)
        #expect(view.text == "Hello new words world")
        #expect(text == "Hello new world")
        #expect(view.textStorage.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? UIColor == .secondaryLabel)
        coordinator.endDictation(transcript.visible)
        #expect(text == "Hello new words world")
        #expect(view.selectedRange == NSRange(location: 15, length: 0))
        let undo = try #require(view.undoManager)
        #expect(undo.undoActionName == "Dictation")
        undo.undo()
        #expect(view.text == "Hello old world")
        #expect(text == view.text)
        undo.redo()
        #expect(view.text == "Hello new words world")
        #expect(text == view.text)
    }

    @Test(arguments: [false, true])
    func dictationDoesNotMergeWithAdjacentNativeTyping(typedBefore: Bool) throws {
        var text = ""
        let editor = ComposerEditorState()
        let input = NativeComposerInput(
            text: Binding(get: { text }, set: { text = $0 }), editor: editor,
            onSend: {}, onCompletionKey: { _ in false }, onPasteImages: { _ in }
        )
        let coordinator = NativeComposerInput.Coordinator(parent: input)
        let view = ComposerTextView()
        view.delegate = coordinator
        view.coordinator = coordinator
        coordinator.input = view
        if typedBefore { view.insertText("Typed") }
        coordinator.anchorDictation()
        var transcript = DictationTranscript()
        transcript.receive("Spoken", isFinal: false)
        coordinator.showDictation(transcript)
        coordinator.endDictation(transcript.visible)
        let dictated = typedBefore ? "Typed Spoken" : "Spoken"
        view.insertText("!")
        #expect(text == dictated + "!")
        let undo = try #require(view.undoManager)
        let groupingIssue: Comment = "t329: UIKit keeps dictation and adjacent typing in one automatic event group."
        undo.undo()
        withKnownIssue(groupingIssue) {
            #expect(text == dictated, "Typing after dictation is its own undo step")
        }
        #expect(view.text == text)
        undo.undo()
        withKnownIssue(groupingIssue) {
            #expect(text == (typedBefore ? "Typed" : ""), "Dictation is its own undo step")
        } when: { typedBefore }
        #expect(view.text == text)
        if typedBefore {
            withKnownIssue(groupingIssue) {
                #expect(undo.canUndo)
            }
            undo.undo()
            #expect(text.isEmpty, "Typing before dictation remains a separate undo step")
            #expect(view.text.isEmpty)
        }
        undo.redo()
        if typedBefore { undo.redo() }
        withKnownIssue(groupingIssue) {
            #expect(text == dictated)
        }
        undo.redo()
        #expect(text == dictated + "!")
        #expect(view.text == text)
    }

    @Test(arguments: [false, true])
    func aFocusedNativeEditorKeepsDictationSeparateFromAdjacentTyping(typedBefore: Bool) throws {
        var text = ""
        let editor = ComposerEditorState()
        let input = NativeComposerInput(
            text: Binding(get: { text }, set: { text = $0 }), editor: editor,
            onSend: {}, onCompletionKey: { _ in false }, onPasteImages: { _ in }
        )
        let coordinator = NativeComposerInput.Coordinator(parent: input)
        let view = ComposerTextView()
        view.delegate = coordinator
        view.coordinator = coordinator
        coordinator.input = view
        editor.textView = view
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(view)
        view.frame = CGRect(x: 20, y: 100, width: 400, height: 120)
        window.makeKeyAndVisible()
        defer {
            view.resignFirstResponder()
            window.isHidden = true
        }
        try #require(view.becomeFirstResponder())
        let undo = try #require(view.undoManager)
        if typedBefore { view.insertText("Typed") }
        try #require(coordinator.beginDictation())
        var transcript = DictationTranscript()
        transcript.receive("Spoken", isFinal: false)
        coordinator.showDictation(transcript)
        coordinator.endDictation(transcript.visible)
        let dictated = typedBefore ? "Typed Spoken" : "Spoken"
        view.insertText("!")
        #expect(text == dictated + "!")
        let groupingIssue: Comment = "t329: UIKit keeps dictation and adjacent typing in one automatic event group."
        undo.undo()
        withKnownIssue(groupingIssue) {
            #expect(text == dictated, "Typing after dictation is its own undo step in the focused native editor")
        }
        #expect(view.text == text)
        undo.undo()
        withKnownIssue(groupingIssue) {
            #expect(text == (typedBefore ? "Typed" : ""), "Dictation is its own undo step in the focused native editor")
        } when: { typedBefore }
        #expect(view.text == text)
        if typedBefore {
            withKnownIssue(groupingIssue) {
                #expect(undo.canUndo)
            }
            undo.undo()
            #expect(text.isEmpty)
            #expect(view.text.isEmpty)
        }
        undo.redo()
        if typedBefore { undo.redo() }
        withKnownIssue(groupingIssue) {
            #expect(text == dictated)
        }
        undo.redo()
        #expect(text == dictated + "!")
        #expect(view.text == text)
    }

    @Test(arguments: [false, true])
    func losingTheNativeDictationRangePreservesRecognizedWordsThroughTheDraft(finalizes: Bool) {
        var text = "Typed"
        let editor = ComposerEditorState()
        let input = NativeComposerInput(
            text: Binding(get: { text }, set: { text = $0 }), editor: editor,
            onSend: {}, onCompletionKey: { _ in false }, onPasteImages: { _ in }
        )
        let coordinator = NativeComposerInput.Coordinator(parent: input)
        let view = ComposerTextView()
        view.delegate = coordinator
        view.coordinator = coordinator
        coordinator.input = view
        editor.textView = view
        view.text = text
        view.selectedRange = NSRange(location: text.utf16.count, length: 0)
        coordinator.anchorDictation()
        var transcript = DictationTranscript()
        transcript.receive("Spoken", isFinal: false)
        coordinator.showDictation(transcript)
        #expect(view.text == "Typed Spoken")

        view.text = ""
        if finalizes { coordinator.endDictation(transcript.visible) }
        else { coordinator.showDictation(transcript) }
        #expect(text == "Typed Spoken")
        #expect(view.text == text)
        #expect(coordinator.lastModelText == text)
        #expect(coordinator.dictationSession == nil)
        #expect(!coordinator.isApplyingDictation)
        #expect(view.undoManager?.isUndoRegistrationEnabled == true)
    }

    @Test func nativeUndoDuringLiveDictationEndsThatSessionWithoutRemovingEarlierTyping() async throws {
        let recognizer = MobileTestRecognizer()
        let (session, target) = try dictatingSession(recognizer)
        defer { session.dictation.deactivate() }
        target.input.insertText("Typed")
        await session.dictation.refreshLanguageSupport()
        session.dictation.toggleRecheckingInput()
        await recognizer.waitUntilListening()
        recognizer.send("Spoken", isFinal: false)
        #expect(target.input.text == "Typed Spoken")

        let undo = try #require(target.input.undoManager)
        undo.undo()
        #expect(!session.dictation.isSessionActive, "Native Undo must end the live dictation session")
        #expect(recognizer.isCancelled)
        #expect(target.input.text == "Typed", "The whole live session is one undo step, not the earlier typing")
        #expect(session.draft.text == target.input.text)
        recognizer.send("Late result", isFinal: true)
        #expect(session.draft.text == "Typed", "A result arriving after Undo cannot restore the session")
        #expect(target.input.text == session.draft.text)
    }

    @Test func redoingAnUndoneLiveDictationSessionRestoresWordsWithoutRestartingRecognition() async throws {
        let recognizer = MobileTestRecognizer()
        let (session, target) = try dictatingSession(recognizer)
        defer { session.dictation.deactivate() }
        target.input.insertText("Typed")
        await session.dictation.refreshLanguageSupport()
        session.dictation.toggleRecheckingInput()
        await recognizer.waitUntilListening()
        recognizer.send("Spoken", isFinal: false)
        let undo = try #require(target.input.undoManager)
        undo.undo()
        #expect(target.input.text == "Typed")
        undo.redo()
        #expect(target.input.text == "Typed Spoken")
        #expect(session.draft.text == target.input.text)
        try #require(target.input.text.utf16.count > 6)
        #expect(target.input.textStorage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? UIColor == .label)
        #expect(!session.dictation.isSessionActive)
        #expect(recognizer.isCancelled)
        #expect(target.input.undoManager === undo)
        undo.undo()
        #expect(target.input.text == "Typed")
        #expect(session.draft.text == target.input.text)
    }

    @Test func discardedTentativeWordsDoNotLeaveAnEmptyUndoStepOrRemoveEarlierHistory() throws {
        var text = ""
        let input = NativeComposerInput(
            text: Binding(get: { text }, set: { text = $0 }), editor: ComposerEditorState(),
            onSend: {}, onCompletionKey: { _ in false }, onPasteImages: { _ in }
        )
        let coordinator = NativeComposerInput.Coordinator(parent: input)
        let view = ComposerTextView()
        view.delegate = coordinator
        view.coordinator = coordinator
        coordinator.input = view
        view.insertText("Typed")
        let undo = try #require(view.undoManager)
        coordinator.anchorDictation()
        var transcript = DictationTranscript()
        transcript.receive("Spoken", isFinal: false)
        coordinator.showDictation(transcript)
        coordinator.endDictation("")
        #expect(view.text == "Typed")
        undo.undo()
        #expect(view.text.isEmpty)
        #expect(text.isEmpty)
        undo.redo()
        #expect(view.text == "Typed")
        #expect(text == view.text)
    }

    @Test func constructingAComposerDoesNotQuerySpeechAssetsDevicesOrPermissions() async throws {
        let probe = MobileDictationProbe()
        let recognizer = MobileTestRecognizer()
        let (session, target) = try dictatingSession(recognizer, probe: probe)
        #expect(probe.localeChecks == 0)
        #expect(probe.deviceChecks == 0)
        #expect(probe.accessChecks == 0)
        #expect(probe.assetChecks == 0)
        #expect(probe.sources == 0)
        await session.dictation.refreshLanguageSupport()
        #expect(probe.localeChecks == 1)
        #expect(probe.deviceChecks == 0)
        #expect(probe.accessChecks == 0)
        #expect(probe.assetChecks == 0)
        #expect(probe.sources == 0)
        #expect(target.input.text.isEmpty)
    }

    @Test func sendWaitsForFinalWordsBeforeCreatingItsOnlyAttempt() async throws {
        let recognizer = MobileTestRecognizer()
        recognizer.finalWords = [("Final words.", true)]
        let (session, target) = try dictatingSession(recognizer, allowsFinalizedPost: true)
        defer { session.dictation.deactivate() }
        await session.dictation.refreshLanguageSupport()
        session.dictation.toggleRecheckingInput()
        await recognizer.waitUntilListening()
        recognizer.send("Uncertain words", isFinal: false)
        #expect(session.draft.text.isEmpty)
        #expect(session.canSend)
        #expect(await !session.send(), "The fixture rejects the finalized POST with 422")
        #expect(session.draft.text == "Final words.")
        #expect(target.input.text == session.draft.text)
        #expect(session.store.sendAttempts.count == 1)
        #expect(session.store.sendAttempts.first?.phase == .notSent)
        #expect(session.draft.sendAttemptID == session.store.sendAttempts.first?.id)
        #expect(!session.dictation.isSessionActive)
        #expect(!session.isFinalizingDictation)
    }

    @Test func unconfirmedDictationKeepsWordsWithoutPostingAndBlocksDuplicateSubmission() async throws {
        let recognizer = MobileTestRecognizer()
        recognizer.stalls = true
        let (session, target) = try dictatingSession(recognizer)
        defer { session.dictation.deactivate() }
        await session.dictation.refreshLanguageSupport()
        session.dictation.toggleRecheckingInput()
        await recognizer.waitUntilListening()
        recognizer.send("Keep these words", isFinal: false)
        let send = Task { await session.send() }
        await recognizer.waitUntilFinishing()
        #expect(session.isFinalizingDictation)
        #expect(!session.canSend)
        #expect(await !session.send())
        recognizer.rejectFinish()
        #expect(await !send.value)
        #expect(session.draft.text == "Keep these words")
        #expect(target.input.text == session.draft.text)
        #expect(session.store.sendAttempts.isEmpty)
        #expect(session.draft.sendAttemptID == nil)
        #expect(session.dictation.notice == .unsent(revision: session.draft.revision))
        #expect(!session.isFinalizingDictation)
    }

    @Test(arguments: [false, true])
    func leavingTheComposerCommitsItsWordsAndRejectsLateResults(dismantles: Bool) async throws {
        let recognizer = MobileTestRecognizer()
        let (session, target) = try dictatingSession(recognizer)
        defer { session.dictation.deactivate() }
        await session.dictation.refreshLanguageSupport()
        session.dictation.toggleRecheckingInput()
        await recognizer.waitUntilListening()
        recognizer.send("Stay in this draft", isFinal: false)
        if dismantles {
            NativeComposerInput.dismantleUIView(target.input, coordinator: target.coordinator)
            #expect(session.editor.textView == nil)
        } else {
            session.dictation.deactivate()
        }
        #expect(recognizer.isCancelled)
        #expect(!session.dictation.isSessionActive)
        #expect(session.draft.text == "Stay in this draft")
        recognizer.send("Late result", isFinal: true)
        #expect(session.draft.text == "Stay in this draft")
        #expect(target.input.text == session.draft.text)
        #expect(session.store.sendAttempts.isEmpty)
    }

    private func dictatingSession(
        _ recognizer: MobileTestRecognizer, probe: MobileDictationProbe = .init(),
        allowsFinalizedPost: Bool = false
    ) throws -> (ComposerSession, MobileDictationTarget) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileDictationProtocol.self]
        let host = allowsFinalizedPost ? "finalized-dictation.test" : "no-dictation-post.test"
        let api = try ChannelAPI(serverURL: "https://\(host)", session: URLSession(configuration: configuration))
        let store = ChannelStore(id: "test", api: api, sendJournal: nil)
        _ = try store.apply(.init(type: "snapshot", state: .init(
            revision: 1,
            channel: .init(id: "test", name: "Test", model: .init(provider: "test", name: "test"),
                           updatedAt: "2026-10-26T00:00:00Z"),
            lead: .lead(id: "test", profile: .init(name: "Lead", role: "Coordinator",
                                                  avatar: .init(mark: "M4 12H20", color: "#123456")))
        )))
        var system = DictationSystem(
            supportedLocale: { probe.localeChecks += 1; return Locale(identifier: "en-US") },
            hasMicrophone: { probe.deviceChecks += 1; return true },
            microphoneAccess: { probe.accessChecks += 1; return .granted },
            requestMicrophoneAccess: { Issue.record("Tests must not request microphone access"); return false },
            speechRecognitionDenied: { false },
            installAssets: { _, _ in probe.assetChecks += 1 },
            makeSource: { probe.sources += 1; return MobileInertAudioSource() },
            makeRecognizer: { _, _, _ in recognizer },
            announce: { _ in },
            openSettings: { _ in Issue.record("Tests must not open Settings") }
        )
        system.refreshNotifications = []
        let draft = ComposerDraft(imageIsReadable: { _ in false })
        let session = ComposerSession(store: store, draft: draft, dictationSystem: system)
        let input = NativeComposerInput(
            text: Binding(get: { draft.text }, set: { draft.text = $0 }), editor: session.editor,
            onSend: {}, onCompletionKey: { _ in false }, onPasteImages: { _ in },
            dictation: session.dictation
        )
        let coordinator = NativeComposerInput.Coordinator(parent: input)
        let view = ComposerTextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.delegate = coordinator
        view.coordinator = coordinator
        coordinator.input = view
        session.editor.textView = view
        let target = MobileDictationTarget(input: view, coordinator: coordinator)
        session.dictation.target = target
        return (session, target)
    }

    @Test func aFailedRequestRevealRetainsItsQuestionThroughRetryUntilSettledSuccess() {
        var preview = ComposerRequestPreviewState()
        let question = ComposerRequestPreviewState.Question(sequence: 40, text: "The original question")
        let first = UUID()
        preview.begin(question, token: first)
        preview.update(.init(token: first, sequence: 40, outcome: .failed("Page returned 503")),
                       requestSequence: 40, currentToken: first)
        #expect(preview.isPresented)
        #expect(preview.question == question)
        #expect(preview.outcome == .failed("Page returned 503"))
        let retry = UUID()
        preview.begin(question, token: retry)
        #expect(preview.isPresented)
        #expect(preview.outcome == .loading)
        preview.update(.init(token: first, sequence: 40, outcome: .failed("An obsolete failure")),
                       requestSequence: 40, currentToken: retry)
        #expect(preview.outcome == .loading)
        preview.update(.init(token: retry, sequence: 41, outcome: .failed("A different request")),
                       requestSequence: 40, currentToken: retry)
        #expect(preview.outcome == .loading)
        preview.update(.init(token: retry, sequence: 40, outcome: .revealed),
                       requestSequence: 40, currentToken: retry)
        #expect(!preview.isPresented)
        #expect(preview.outcome == .revealed)
    }

    @Test func dismissedAndSupersededRequestFailuresNeverReopenTheirPreview() {
        for supersedesRequest in [false, true] {
            var preview = ComposerRequestPreviewState()
            let token = UUID()
            preview.begin(.init(sequence: 40, text: "Retained"), token: token)
            preview.update(.init(token: token, sequence: 40, outcome: .failed("Failure")),
                           requestSequence: 40, currentToken: token)
            preview.dismiss()
            preview.update(.init(token: token, sequence: 40, outcome: .failed("Later failure")),
                           requestSequence: 40, currentToken: token)
            #expect(!preview.isPresented)
            preview.update(.init(token: token, sequence: 40, outcome: .failed("Obsolete")),
                           requestSequence: supersedesRequest ? 41 : 40,
                           currentToken: supersedesRequest ? token : UUID())
            #expect(preview.question == nil)
            #expect(preview.token == nil)
            #expect(!preview.isPresented)
        }
    }

    @MainActor private final class MobileDictationProbe {
        var localeChecks = 0
        var deviceChecks = 0
        var accessChecks = 0
        var assetChecks = 0
        var sources = 0
    }

    @MainActor private final class MobileDictationTarget: DictationTextTarget {
        let input: ComposerTextView
        let coordinator: NativeComposerInput.Coordinator
        var isInKeyWindow: Bool { false }

        init(input: ComposerTextView, coordinator: NativeComposerInput.Coordinator) {
            self.input = input
            self.coordinator = coordinator
        }

        func beginDictation() -> Bool {
            coordinator.anchorDictation()
            return coordinator.dictationSession != nil
        }

        func showDictation(_ transcript: DictationTranscript) { coordinator.showDictation(transcript) }
        func endDictation(_ finalized: String) { coordinator.endDictation(finalized) }
    }

    private final class MobileInertAudioSource: DictationAudioSource {
        func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws {
            Issue.record("Unit tests must not start audio capture")
            throw ChannelAPIError.invalidResponse
        }
        func stop() {}
    }

    @MainActor private final class MobileTestRecognizer: DictationRecognizing {
        var finalWords: [(String, Bool)] = []
        var stalls = false
        private(set) var isCancelled = false
        private let listening = AsyncStream.makeStream(of: Void.self)
        private let finishing = AsyncStream.makeStream(of: Void.self)
        private var result: (@MainActor (String, Bool) -> Void)?
        private var finishContinuation: CheckedContinuation<Void, any Error>?

        func start(onListening: @escaping @MainActor () -> Void,
                   onResult: @escaping @MainActor (String, Bool) -> Void,
                   onLevel: @escaping @MainActor @Sendable (Double) -> Void,
                   onInterruption: @escaping @MainActor @Sendable () -> Void,
                   onFailure: @escaping @MainActor (any Error) -> Void) async throws {
            result = onResult
            onListening()
            listening.continuation.yield()
        }

        func waitUntilListening() async {
            var events = listening.stream.makeAsyncIterator()
            _ = await events.next()
        }

        func waitUntilFinishing() async {
            var events = finishing.stream.makeAsyncIterator()
            _ = await events.next()
        }

        func send(_ text: String, isFinal: Bool) { result?(text, isFinal) }

        func finish() async throws {
            finishing.continuation.yield()
            if stalls { try await withCheckedThrowingContinuation { finishContinuation = $0 } }
            for (text, isFinal) in finalWords { result?(text, isFinal) }
        }

        func rejectFinish() {
            finishContinuation?.resume(throwing: ChannelAPIError.invalidResponse)
            finishContinuation = nil
        }

        func cancel() {
            isCancelled = true
            finishContinuation?.resume(throwing: CancellationError())
            finishContinuation = nil
        }
    }

    private final class MobileDictationProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            do {
                #expect(request.url?.host == "finalized-dictation.test", "Unconfirmed dictation must not post")
                #expect(request.httpMethod == "POST")
                let payload = try JSONDecoder().decode(Payload.self, from: body())
                #expect(payload.content == "Final words.", "The POST contains finalized words, never the tentative display")
                #expect(UUID(uuidString: payload.id) != nil)
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 422, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                ))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"error":"Rejected after finalization"}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                Issue.record(error)
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        private func body() throws -> Data {
            if let body = request.httpBody { return body }
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw stream.streamError ?? ChannelAPIError.invalidResponse }
                if count == 0 { return data }
                data.append(contentsOf: buffer.prefix(count))
            }
        }

        private struct Payload: Decodable {
            let id: String
            let content: String
        }
    }

    @Test func contextAndPopoverFailuresUseOneSurfaceAndNavigationInvalidatesIt() {
        var preview = ComposerRequestPreviewState()
        let token = UUID()
        preview.contextAppeared()
        preview.begin(.init(sequence: 40, text: "Question"), token: token)
        preview.update(.init(token: token, sequence: 40, outcome: .failed("Failure")),
                       requestSequence: 40, currentToken: token)
        #expect(!preview.isPresented, "The native context preview already shows the failure")
        #expect(preview.outcome == .failed("Failure"))
        preview.contextDisappeared()
        preview.update(.init(token: token, sequence: 40, outcome: .failed("Late failure")),
                       requestSequence: 40, currentToken: token)
        #expect(!preview.isPresented)
        preview.invalidate()
        preview.update(.init(token: token, sequence: 40, outcome: .failed("After navigation")),
                       requestSequence: 40, currentToken: token)
        #expect(preview.question == nil)
        #expect(!preview.isPresented)
    }

    @Test func anObsoleteRequestPreviewDismissalCannotUncoverItsReplacement() {
        let interaction = ChannelInteraction()
        let first = UUID()
        let replacement = UUID()
        interaction.requestPreviewDidAppear(first)
        #expect(interaction.isRequestPreviewPresented)
        interaction.requestPreviewDidAppear(replacement)
        interaction.requestPreviewDidDisappear(first)
        #expect(interaction.isRequestPreviewPresented)
        interaction.requestPreviewDidDisappear(replacement)
        #expect(!interaction.isRequestPreviewPresented)
        interaction.requestPreviewDidDisappear(first)
        #expect(!interaction.isRequestPreviewPresented)
    }

    @Test func supersessionKeepsClosingPreviewContentButRejectsLateResults() {
        var preview = ComposerRequestPreviewState()
        let question = ComposerRequestPreviewState.Question(sequence: 40, text: "Closing question")
        let token = UUID()
        preview.begin(question, token: token)
        preview.update(.init(token: token, sequence: 40, outcome: .failed("Failure")),
                       requestSequence: 40, currentToken: token)
        #expect(preview.isPresented)
        preview.update(nil, requestSequence: 41, currentToken: UUID())
        #expect(!preview.isPresented)
        #expect(preview.question == question)
        #expect(preview.token == nil)
        #expect(preview.outcome == nil)
        preview.update(.init(token: token, sequence: 40, outcome: .failed("Late failure")),
                       requestSequence: 40, currentToken: token)
        #expect(!preview.isPresented)
    }

    @Test func leavingTheRequestContextBeforeFailureKeepsItsErrorWithoutOpeningAPreview() {
        var preview = ComposerRequestPreviewState()
        let question = ComposerRequestPreviewState.Question(sequence: 40, text: "Retained question")
        let token = UUID()
        preview.begin(question, token: token)
        preview.dismiss()
        preview.update(.init(token: token, sequence: 40, outcome: .failed("Actual operation error")),
                       requestSequence: 40, currentToken: token)
        #expect(!preview.isPresented)
        #expect(preview.question == question)
        #expect(preview.outcome == .failed("Actual operation error"))
    }
}
