import AppKit
import ChannelKit
import Foundation
import Speech
import SwiftUI
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import ToyBoxDesktop

@MainActor @Suite(.timeLimit(.minutes(1)))
struct ComposerTests {
    @Test func textAndOriginalSendIDSurviveRestoration() async throws {
        try await withDraft { draft, url in
            #expect(!draft.hasContent)
            draft.text = "@lead First draft"
            draft.associateSend(id: "original-send-id")
            let restored = ComposerDraft(fileURL: url)
            #expect(draft.error == nil)
            #expect(restored.text == draft.text)
            #expect(restored.sendAttemptID == "original-send-id")
            draft.text = "A newer draft"
            #expect(draft.sendAttemptID == nil)
        }
    }

    @Test func anOldCompletionCannotEraseANewerDraft() async throws {
        try await withDraft { draft, _ in
            draft.text = "Original"
            let originalRevision = draft.revision
            draft.associateSend(id: "original")
            draft.text = "A newer draft"
            draft.clear(ifUnchanged: originalRevision)
            #expect(draft.text == "A newer draft")
            #expect(draft.hasContent)
        }
    }

    @Test func imagesPersistSeparatelyFromTextMetadata() async throws {
        try await withDraft { draft, url in
            let image = try sampleImage()
            draft.append(image)
            #expect(draft.hasContent)
            #expect(!draft.hasUnreadableImage)
            let restored = ComposerDraft(fileURL: url)
            #expect(restored.images.first?.data == image.data)
            let metadata = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
            #expect(!metadata.contains(image.data.base64EncodedString()))
            draft.associateSend(id: "with-image")
            draft.removeImage(id: image.id)
            #expect(draft.images.isEmpty)
            #expect(draft.sendAttemptID == nil)
            let imageURL = url.deletingPathExtension().appendingPathComponent(image.id.uuidString)
            #expect(!FileManager.default.fileExists(atPath: imageURL.path))
        }
    }

    @Test func missingRestoredImagesRequireReattachment() async throws {
        try await withDraft { draft, url in
            let image = try sampleImage()
            draft.append(image)
            let imageURL = url.deletingPathExtension().appendingPathComponent(image.id.uuidString)
            try FileManager.default.removeItem(at: imageURL)
            let restored = ComposerDraft(fileURL: url)
            #expect(restored.images.count == 1)
            #expect(restored.hasUnreadableImage)
            #expect(restored.error?.contains("attach") == true)
        }
    }

    @Test func attachmentOnlyDraftClearsItsOriginalUUID() async throws {
        try await withDraft { draft, url in
            draft.append(try sampleImage())
            draft.associateSend(id: "attachment-only")
            draft.clear(ifUnchanged: draft.revision)
            #expect(!draft.hasContent)
            #expect(draft.images.isEmpty)
            #expect(draft.sendAttemptID == nil)
            let restored = ComposerDraft(fileURL: url)
            #expect(!restored.hasContent)
            #expect(restored.sendAttemptID == nil)
        }
    }

    @Test func restoringASendRetainsUnreadableImagesUntilReattachment() async throws {
        try await withDraft { draft, url in
            let readable = try sampleImage()
            let attachments: [ChannelAttachment] = [
                .init(name: "Missing.png", mimeType: "image/png"),
                .init(name: "Corrupt.png", mimeType: "image/png",
                      base64: Data([1, 2, 3]).base64EncodedString()),
                .init(name: "Missing type.png", base64: readable.data.base64EncodedString()),
                readable.attachment,
            ]
            draft.restore(content: "Keep every attachment", attachments: attachments,
                          sendAttemptID: "original")
            #expect(draft.images.count == attachments.count)
            #expect(draft.hasUnreadableImage)
            #expect(draft.images.last?.data == readable.data)
            #expect(draft.sendAttemptID == "original")
            #expect(draft.error?.contains("before sending") == true)
            let restored = ComposerDraft(fileURL: url)
            #expect(restored.images.count == attachments.count)
            #expect(restored.hasUnreadableImage)
            #expect(restored.error?.contains("attach") == true)
            for image in draft.images where image.image == nil { draft.removeImage(id: image.id) }
            #expect(draft.images.count == 1)
            #expect(!draft.hasUnreadableImage)
            #expect(draft.sendAttemptID == nil)
        }
    }

    @Test func storageKeysNormalizeAndIsolateServersAndChannels() throws {
        let upper = try #require(URL(string: "HTTP://LOCALHOST:80/prefix///"))
        let normalized = try #require(URL(string: "http://localhost/prefix"))
        let otherServer = try #require(URL(string: "http://localhost:3210/prefix"))
        let key = ComposerDraft.storageKey(serverURL: upper, channelID: "channel")
        #expect(key == ComposerDraft.storageKey(serverURL: normalized, channelID: "channel"))
        #expect(key != ComposerDraft.storageKey(serverURL: otherServer, channelID: "channel"))
        #expect(key != ComposerDraft.storageKey(serverURL: normalized, channelID: "another"))
    }

    @Test func mentionContextUsesCaretAndCanonicalBoundaries() {
        let text = "Hello, @Pi"
        let context = ComposerMentionContext.match(text: text, selection: .init(location: text.utf16.count, length: 0))
        #expect(context?.query == "pi")
        #expect(context?.range == NSRange(location: 7, length: 3))
        #expect(ComposerMentionContext.match(text: "a@pixel", selection: .init(location: 7, length: 0)) == nil)
        #expect(ComposerMentionContext.match(text: "@pi", selection: .init(location: 3, length: 1)) == nil)
        #expect(ComposerMentionContext.match(text: "@pi", selection: .init(location: NSNotFound, length: 0)) == nil)
        // A line break after the token ends it, even though `$` alone would match before one.
        #expect(ComposerMentionContext.match(text: "@\n", selection: .init(location: 2, length: 0)) == nil)
        let emoji = "\u{1f642} @pi"
        #expect(ComposerMentionContext.match(text: emoji, selection: .init(location: emoji.utf16.count, length: 0))?.range
                == NSRange(location: 3, length: 3))
    }

    @Test func completionUsesCanonicalMatchingOrderAndCreateRules() {
        let agents: [ChannelAgent] = [
            .lead(id: "lead"),
            .init(id: "z", name: "Zebra", role: "Design"),
            .init(id: "a", name: "Ada", role: "Engineering"),
            .init(id: "p", name: "Pixel", role: "Design"),
        ]
        #expect(MentionChoice.items(query: "", agents: agents).map(\.name)
                == ["Everyone", "Lead", "Ada", "Pixel", "Zebra"])
        #expect(MentionChoice.items(query: "design", agents: agents).filter { !$0.isCreate }.map(\.name)
                == ["Pixel", "Zebra"])
        #expect(MentionChoice.items(query: "pixel", agents: agents).allSatisfy { !$0.isCreate })
        let create = MentionChoice.items(query: "new-person", agents: agents).last
        #expect(create?.isCreate == true)
        #expect(create?.name == "New Person")
        #expect(MentionChoice.items(query: "ada", agents: agents).first?.isMember == true)
        #expect(MentionChoice.items(query: "lead", agents: agents).first?.isMember == false)
    }

    @Test func importingImagesRejectsUnsupportedAndUnreadableFilesExplicitly() async throws {
        try await withDraft { draft, url in
            let image = try sampleImage()
            let imageURL = url.deletingLastPathComponent().appendingPathComponent("sample.png")
            try image.data.write(to: imageURL)
            draft.attachFiles([imageURL])
            try await finishLoading(draft)
            #expect(draft.images.count == 1)
            #expect(draft.error == nil)
            let unsupported = url.deletingLastPathComponent().appendingPathComponent("not-image.txt")
            try Data("Not an image".utf8).write(to: unsupported)
            draft.attachFiles([unsupported])
            try await finishLoading(draft)
            #expect(draft.images.count == 1)
            #expect(draft.error?.contains("not-image.txt") == true)
            draft.append(.init(name: "broken.png", mimeType: "image/png", data: Data([1, 2, 3])))
            #expect(draft.images.count == 1)
            #expect(draft.error?.contains("broken.png") == true)
        }
    }

    @Test func persistenceFailureIsVisibleAndDoesNotEraseText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-composer-\(UUID())")
        try Data("Not a directory".utf8).write(to: directory)
        defer { remove(directory) }
        let draft = ComposerDraft(fileURL: directory.appendingPathComponent("draft.json"))
        draft.text = "Keep this text"
        #expect(draft.text == "Keep this text")
        #expect(draft.error?.contains("could not be saved") == true)
        #expect(!draft.isSavedLocally)
    }

    @Test func aDropIsPendingUntilItsImageDataHasBeenRead() async throws {
        try await withDraft { draft, _ in
            let image = try sampleImage()
            let provider = NSItemProvider()
            provider.suggestedName = "Dropped.png"
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                completion(image.data, nil)
                return nil
            }
            #expect(draft.attachProvider(provider))
            #expect(draft.isLoadingImages)
            try await finishLoading(draft)
            #expect(draft.images.count == 1)
            #expect(draft.images.first?.name == "Dropped.png")
            #expect(draft.images.first?.data == image.data)
        }
    }

    @Test func returnSendsButShiftReturnAndIMECompositionDoNot() throws {
        var sends = 0
        let parent = NativeComposerInput(
            text: .constant("Draft"), height: .constant(44), focused: .constant(false),
            dragging: .constant(false), fontSize: 14, focusRequest: UUID(),
            agents: [.lead(id: "lead")], canManage: false,
            onSend: { sends += 1 }, onFiles: { _ in }, onImage: { _ in },
            onError: { _ in }, onCreate: { .init(id: "created", name: $0) }, onEdit: { _ in }
        )
        let coordinator = parent.makeCoordinator()
        let input = ComposerTextView(frame: .init(x: 0, y: 0, width: 400, height: 60))
        coordinator.input = input
        func key(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            ))
        }
        #expect(try coordinator.handle(key([])))
        #expect(try coordinator.handle(key(.command)))
        #expect(sends == 2)
        #expect(try !coordinator.handle(key(.shift)))
        #expect(sends == 2)
        input.setMarkedText("\u{5019}\u{88dc}", selectedRange: .init(location: 2, length: 0),
                            replacementRange: .init(location: NSNotFound, length: 0))
        #expect(input.hasMarkedText())
        #expect(try !coordinator.handle(key([])))
        #expect(sends == 2)
        input.unmarkText()
    }

    @Test func nativeEditingKeepsShiftReturnAndUndoInTheDraft() throws {
        var text = ""
        var sends = 0
        let parent = NativeComposerInput(
            text: .init(get: { text }, set: { text = $0 }), height: .constant(44),
            focused: .constant(false), dragging: .constant(false), fontSize: 14,
            focusRequest: UUID(), agents: [.lead(id: "lead")], canManage: false,
            onSend: { sends += 1 }, onFiles: { _ in }, onImage: { _ in },
            onError: { _ in }, onCreate: { .init(id: "created", name: $0) }, onEdit: { _ in }
        )
        let coordinator = parent.makeCoordinator()
        let input = ComposerTextView(frame: .init(x: 0, y: 0, width: 400, height: 80))
        input.isRichText = false
        input.allowsUndo = true
        input.delegate = coordinator
        input.coordinator = coordinator
        coordinator.input = input
        let window = NSWindow(contentRect: input.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = input
        defer { window.close() }
        #expect(window.makeFirstResponder(input))
        let undo = try #require(input.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        input.insertText("First line", replacementRange: .init(location: 0, length: 0))
        undo.endUndoGrouping()
        input.breakUndoCoalescing()
        #expect(text == "First line")
        let newline = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        undo.beginUndoGrouping()
        input.keyDown(with: newline)
        input.insertText("Second line", replacementRange: input.selectedRange())
        undo.endUndoGrouping()
        #expect(text == "First line\nSecond line")
        #expect(sends == 0)
        undo.undo()
        #expect(input.string == "First line")
        #expect(text == input.string)
        undo.redo()
        #expect(text == "First line\nSecond line")
        #expect(text == input.string)
    }

    @Test func pasteboardImagesAndFilesUseTheSameImportCallbacks() throws {
        var images: [ComposerImage] = []
        var files: [URL] = []
        let parent = NativeComposerInput(
            text: .constant(""), height: .constant(44), focused: .constant(false),
            dragging: .constant(false), fontSize: 14, focusRequest: UUID(),
            agents: [], canManage: false, onSend: {}, onFiles: { files += $0 },
            onImage: { images.append($0) }, onError: { _ in },
            onCreate: { .init(id: "created", name: $0) }, onEdit: { _ in }
        )
        let coordinator = parent.makeCoordinator()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = try sampleImage()
        #expect(pasteboard.setData(image.data, forType: .png))
        #expect(coordinator.acceptPasteboard(pasteboard))
        #expect(images.first?.data == image.data)
        #expect(images.first?.mimeType == "image/png")
        pasteboard.clearContents()
        let file = URL(fileURLWithPath: "/tmp/composer-pasteboard-fixture.png")
        #expect(pasteboard.writeObjects([file as NSURL]))
        #expect(coordinator.acceptPasteboard(pasteboard))
        #expect(files == [file])
        #expect(images.count == 1)
        pasteboard.clearContents()
        #expect(pasteboard.setString("Ordinary text", forType: .string))
        #expect(!coordinator.acceptPasteboard(pasteboard))
    }

    @Test func consecutiveNativeKeystrokesKeepTheirCaretThroughSwiftUIUpdates() async throws {
        let draft = ComposerDraft()
        let host = NSHostingView(rootView: ComposerInputTestHost(draft: draft))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 140)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let input = try #require(composerInput(in: host))
        #expect(window.makeFirstResponder(input))
        for (index, character) in ["a", "b", "c"].enumerated() {
            let key = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0
            ))
            input.keyDown(with: key)
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
            #expect(input.string == String("abc".prefix(index + 1)))
            #expect(draft.text == input.string)
            #expect(input.selectedRange() == NSRange(location: index + 1, length: 0))
        }
        input.setAccessibilityValue("Accessible edit")
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        #expect(input.string == "Accessible edit")
        #expect(draft.text == input.string)
    }

    @Test func tabLeavesTheComposerLikeATextareaUnlessItAcceptsAMention() async throws {
        let draft = ComposerDraft()
        // AppKit neighbors keep these focus moves out of SwiftUI's focus state, which tests running
        // alongside this one rely on to focus their own fields.
        let before = NSTextField(string: "")
        before.placeholderString = "Before"
        let after = NSTextField(string: "")
        after.placeholderString = "After"
        let stack = NSStackView(views: [before, NSHostingView(rootView: ComposerInputTestHost(draft: draft)), after])
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 400, height: 220)
        let window = NSWindow(contentRect: stack.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stack
        // The mention popover only shows from an ordered-in window, so keep it out of sight.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer {
            // Resigning closes any open mention popover before the window goes.
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.close()
        }
        stack.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let input = try #require(composerInput(in: stack))
        func press(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) async throws {
            input.keyDown(with: try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            )))
            try await Task.sleep(for: .milliseconds(30))
        }
        func type(_ text: String) async throws {
            #expect(window.makeFirstResponder(input))
            input.string = ""
            input.insertText(text, replacementRange: input.selectedRange())
            try await Task.sleep(for: .milliseconds(30))
        }
        var focusedField: String? {
            let responder: AnyObject? = (window.firstResponder as? NSText)?.delegate ?? window.firstResponder
            return (responder as? NSTextField)?.placeholderString
        }

        try await type("Hello")
        try await press(48, "\t")
        #expect(focusedField == "After")
        try await type("Hello")
        try await press(48, "\u{19}", .shift)
        #expect(focusedField == "Before")
        #expect(draft.text == "Hello")
        try await type("Hello")
        try await press(48, "\t", .option)
        #expect(window.firstResponder === input)
        #expect(draft.text == "Hello\t")

        // With the mention list open, Tab accepts like Return. Shift still moves back, as in the pane,
        // and Option-Tab is still a literal tab.
        try await type("@")
        try await press(125, "\u{f701}")
        try await press(48, "\t")
        #expect(window.firstResponder === input)
        #expect(draft.text == "@lead ")
        try await type("@")
        try await press(48, "\u{19}", .shift)
        #expect(focusedField == "Before")
        #expect(draft.text == "@")
        try await type("@")
        try await press(48, "\t", .option)
        #expect(window.firstResponder === input)
        #expect(draft.text == "@\t")
        try await type("@")
        try await press(36, "\r", .shift)
        #expect(draft.text == "@\n")
        // The new line ends the mention, so Return sends rather than accepting one.
        try await press(36, "\r")
        #expect(draft.text == "@\n")
    }

    @Test func modelSynchronizationDoesNotOverwriteAnInProgressNativeEdit() {
        let draft = ComposerDraft()
        draft.text = "Seed"
        let parent = NativeComposerInput(
            text: .init(get: { draft.text }, set: { draft.text = $0 }), height: .constant(44),
            focused: .constant(false), dragging: .constant(false), fontSize: 14, focusRequest: UUID(),
            agents: [], canManage: false, onSend: {}, onFiles: { _ in }, onImage: { _ in },
            onError: { _ in }, onCreate: { .init(id: "created", name: $0) }, onEdit: { _ in }
        )
        let coordinator = parent.makeCoordinator()
        let input = ComposerTextView()
        coordinator.input = input
        input.string = "Seedabc"
        input.setSelectedRange(NSRange(location: 7, length: 0))
        coordinator.synchronizeModelText("Seed")
        #expect(input.string == "Seedabc")
        #expect(input.selectedRange() == NSRange(location: 7, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(draft.text == "Seedabc")
        draft.text = "Reply: Seedabc"
        coordinator.synchronizeModelText(draft.text)
        #expect(input.string == draft.text)
        #expect(input.selectedRange() == NSRange(location: draft.text.utf16.count, length: 0))
        input.setSelectedRange(NSRange(location: 2, length: 4))
        draft.text += "!"
        coordinator.synchronizeModelText(draft.text)
        #expect(input.selectedRange() == NSRange(location: 2, length: 4))
    }

    @Test func sendFailureAnnouncementsUseFreshEventsForRepeatedSameMessageFailures() {
        var announcements = ComposerFailureAnnouncements()
        let uncertain = ComposerFailureFeedback(id: "first-failure-event",
                                                message: "Delivery not confirmed.")
        let changedError = ComposerFailureFeedback(id: uncertain.id, message: "A changed error.")
        let retry = ComposerFailureFeedback(id: "retry-failure-event", message: uncertain.message)
        let received = [
            announcements.receive(uncertain, isEligible: false),
            announcements.receive(uncertain, isEligible: true),
            announcements.receive(uncertain, isEligible: true),
            announcements.receive(changedError, isEligible: true),
            announcements.receive(retry, isEligible: true),
            announcements.receive(retry, isEligible: true),
            announcements.receive(uncertain, isEligible: true),
        ]
        #expect(received == [false, true, false, false, true, false, false])
    }

    @Test func trayVisibilityTracksArtifactsTasksAndPreview() {
        var channel = Channel(id: "tray", name: "Tray", model: .init(provider: "test", name: "test"),
                              latestSequence: 1, seenThrough: 1, updatedAt: "2026-10-22T08:00:00Z")
        let empty = ChannelState(revision: 1, channel: channel, lead: .lead(id: channel.id))
        #expect(!ComposerTray.isVisible(for: empty))
        channel.tasks = [.init(id: "task", title: "Task")]
        #expect(ComposerTray.isVisible(for: ChannelState(revision: 2, channel: channel, lead: .lead(id: channel.id))))
    }

    @Test func trayTaskPopoverAlignsStatusIconsWithItsHeadingAndTrailsDisclosures() async throws {
        var channel = Channel(id: "tasks", name: "Tasks", model: .init(provider: "test", name: "test"),
                              latestSequence: 1, seenThrough: 1, updatedAt: "2026-10-22T08:00:00Z")
        channel.tasks = [
            .init(id: "parent", title: "Parent task", status: "blocked", children: [
                .init(id: "child", title: "Child task", status: "done")
            ])
        ]
        let state = ChannelState(revision: 1, channel: channel, lead: .lead(id: channel.id))
        let size = NSSize(width: ComposerTasksPopover.width, height: 240)
        // A popover inherits the tray button's environment, so host it under the tray's label styling.
        let view = NSHostingView(rootView:
            ComposerTasksPopover(state: state, onArtifactOpen: { _ in })
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color.white)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / size.width

        var pixels: [(x: Int, y: Int, color: NSColor)] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { pixels.append((x, y, color)) }
            }
        }
        let isGreen = { (c: NSColor) in c.greenComponent - c.redComponent > 0.08 && c.greenComponent - c.blueComponent > 0.08 }
        let isRed = { (c: NSColor) in c.redComponent - c.greenComponent > 0.3 && c.redComponent - c.blueComponent > 0.3 }
        let isInk = { (c: NSColor) in (c.redComponent + c.greenComponent + c.blueComponent) / 3 < 0.6 }
        func minX(_ matches: [(x: Int, y: Int, color: NSColor)]) -> CGFloat? {
            matches.map(\.x).min().map { CGFloat($0) / scale }
        }

        let parentStatus = pixels.filter { isRed($0.color) }
        let listTop = try #require(parentStatus.map(\.y).min())
        let parentBottom = try #require(parentStatus.map(\.y).max())
        let heading = try #require(minX(pixels.filter { $0.y < listTop - Int(4 * scale) && isInk($0.color) }))
        let parent = try #require(minX(parentStatus))
        let child = try #require(minX(pixels.filter { isGreen($0.color) }))
        #expect(abs(heading - ComposerTasksPopover.inset) < 1.5, "Heading starts at \(heading)")
        #expect(abs(parent - heading) < 1.5, "Root status \(parent), heading \(heading)")
        let titleStart = parent + OverviewTaskRow.statusSize + OverviewTaskRow.titleGap
        #expect(abs(child - titleStart) < 1.5, "Child status \(child) should sit under its parent's title at \(titleStart)")

        let list = pixels.filter { $0.y >= listTop - Int(2 * scale) && isInk($0.color) }
        let leftmost = try #require(minX(list))
        #expect(leftmost > parent - 1, "Nothing may hang left of the status column, found ink at \(leftmost)")

        let firstLine = list.filter { $0.y <= parentBottom }
        let lineEnd = try #require(firstLine.map(\.x).max().map { CGFloat($0) / scale })
        let titleWidth = ("Parent task" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        #expect(lineEnd > titleStart + titleWidth + 6,
                "The disclosure should trail the title, but the first line ends at \(lineEnd)")

        func darkest(_ matches: [(x: Int, y: Int, color: NSColor)]) -> CGFloat? {
            matches.map { ($0.color.redComponent + $0.color.greenComponent + $0.color.blueComponent) / 3 }.min()
        }
        let headingInk = try #require(darkest(pixels.filter {
            $0.y < listTop - Int(4 * scale) && CGFloat($0.x) / scale < size.width / 2
        }))
        let titleInk = try #require(darkest(firstLine.filter {
            CGFloat($0.x) / scale > titleStart && CGFloat($0.x) / scale < titleStart + titleWidth
        }))
        #expect(headingInk < titleInk + 0.08,
                "The heading should be primary ink like an open task's title, not the tray's secondary (\(headingInk) vs \(titleInk))")
    }

    /// Mouse users get legacy scrollers, which `.hidden` still shows. Run with `-AppleShowScrollBars Always`
    /// to exercise that locally. GitHub's runners use legacy scrollers already.
    @Test func imageStripKeepsOneHeightWhenItsImagesOverflowAndStillScrolls() async throws {
        let draft = ComposerDraft()
        for _ in 0..<6 { draft.append(try sampleImage()) }
        var heights: [CGFloat] = []
        var geometry: [String] = []
        // Six 68pt tiles need 482pt, so they overflow at 160 and fit at 640.
        for width: CGFloat in [160, 640] {
            let view = NSHostingView(rootView: ComposerImageStrip(draft: draft)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            heights.append(view.fittingSize.height)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let scrollViews = descendants(view).compactMap { $0 as? NSScrollView }
            geometry.append("\(view.fittingSize) at \(width): " + scrollViews.map {
                "\($0.frame.size) horizontal scroller \($0.hasHorizontalScroller ? "\($0.horizontalScroller?.frame.size ?? .zero)" : "none")"
            }.joined(separator: ", "))

            // Hiding the scroller must not strand the overflow: a trackpad or Shift-wheel still reaches it.
            guard width == 160 else { continue }
            let scrollView = try #require(scrollViews.first)
            for _ in 0..<60 where scrollView.contentView.bounds.minX <= 0 {
                let notch = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                                 wheel1: 0, wheel2: -3, wheel3: 0))
                scrollView.scrollWheel(with: try #require(NSEvent(cgEvent: notch)))
                try await Task.sleep(for: .milliseconds(16))
            }
            #expect(scrollView.contentView.bounds.minX > 0, "The overflowing strip should scroll sideways")
        }
        let style = NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay"
        #expect(heights[0] == heights[1], "\(style) scrollers. \(geometry.joined(separator: "; "))")
    }

    @Test func dictationTranscriptJoinsTranscriberSegmentsAndPadsAgainstTheDraft() {
        var transcript = DictationTranscript()
        let changed = transcript.receive(" Can you tighten the sidebar", isFinal: false)
        #expect(changed)
        #expect(transcript.visible == "Can you tighten the sidebar")
        #expect(transcript.finalized.isEmpty)
        transcript.receive("Can you tighten the sidebar spacing", isFinal: true)
        transcript.receive("?", isFinal: true)
        transcript.receive(" and check the", isFinal: false)
        #expect(transcript.finalized == "Can you tighten the sidebar spacing?")
        #expect(transcript.visible == "Can you tighten the sidebar spacing? and check the")
        let repeated = transcript.receive(" and check the", isFinal: false)
        #expect(!repeated)
        transcript.promoteTentative()
        #expect(transcript.finalized == "Can you tighten the sidebar spacing? and check the")
        #expect(transcript.tentative.isEmpty)
        #expect(DictationTranscript.join("Hello", "world") == "Hello world")
        #expect(DictationTranscript.join("Hello", ",") == "Hello,")
        #expect(DictationTranscript.join("Hello\n", "world") == "Hello\nworld")
        let between = DictationTranscript.padding(for: "words", after: "x", before: "y")
        #expect(between.0 == " " && between.1 == " ")
        let afterSpace = DictationTranscript.padding(for: "words", after: " ", before: ".")
        #expect(afterSpace.0.isEmpty && afterSpace.1.isEmpty)
        let punctuation = DictationTranscript.padding(for: "?", after: "d", before: nil)
        #expect(punctuation.0.isEmpty && punctuation.1.isEmpty)
    }

    @Test func dictationShowsTentativeWordsInPlaceAndCommitsFinalWordsAsOneUndoStep() async throws {
        let draft = ComposerDraft()
        draft.text = "Ship it today"
        let recognizer = ManualDictationRecognizer()
        let dictation = ComposerDictation(system: .manual(recognizer))
        let (window, input) = try await hostComposer(draft: draft, dictation: dictation)
        defer { window.close() }
        input.setSelectedRange(NSRange(location: 8, length: 5))
        dictation.toggle()
        try await waitUntil("dictation listens") { dictation.phase == .listening }
        #expect(input.isDictating)

        recognizer.send("tomorrow", isFinal: false)
        #expect(input.string == "Ship it tomorrow")
        #expect(draft.text == "Ship it today", "Tentative words never reach the draft")
        #expect(color(of: input, at: 9) == .secondaryLabelColor)
        #expect(input.selectedRange() == NSRange(location: 16, length: 0))
        #expect(dictation.hasWords)

        recognizer.send("tomorrow", isFinal: true)
        recognizer.send(" morning", isFinal: false)
        #expect(input.string == "Ship it tomorrow morning")
        #expect(draft.text == "Ship it tomorrow")
        #expect(color(of: input, at: 9) == .textColor)
        #expect(color(of: input, at: 18) == .secondaryLabelColor)

        recognizer.finalWords = [(" morning.", true)]
        #expect(await dictation.stop())
        #expect(!dictation.isSessionActive && !input.isDictating)
        #expect(input.string == "Ship it tomorrow morning.")
        #expect(draft.text == input.string)
        #expect(color(of: input, at: 18) == .textColor)
        #expect(input.selectedRange() == NSRange(location: 25, length: 0))

        let undo = try #require(input.undoManager)
        #expect(undo.undoActionName == "Dictation")
        undo.undo()
        #expect(input.string == "Ship it today")
        #expect(draft.text == input.string)
        undo.redo()
        #expect(input.string == "Ship it tomorrow morning.")
    }

    @Test func typingAndEscapeStopDictationWithoutMergingUndoSteps() async throws {
        let draft = ComposerDraft()
        let recognizer = ManualDictationRecognizer()
        let dictation = ComposerDictation(system: .manual(recognizer))
        let (window, input) = try await hostComposer(draft: draft, dictation: dictation)
        defer { window.close() }
        dictation.toggle()
        try await waitUntil("dictation listens") { dictation.phase == .listening }
        recognizer.send("Hello there", isFinal: false)
        #expect(draft.text.isEmpty)

        input.keyDown(with: try key("!", code: 18, in: window))
        #expect(!dictation.isSessionActive)
        #expect(recognizer.isCancelled)
        #expect(input.string == "Hello there!")
        #expect(draft.text == input.string)
        let undo = try #require(input.undoManager)
        undo.undo()
        #expect(input.string == "Hello there", "The typed key is its own undo step")
        undo.undo()
        #expect(input.string.isEmpty)

        dictation.toggle()
        try await waitUntil("dictation listens again") { dictation.phase == .listening }
        recognizer.send("Keep these words", isFinal: false)
        input.keyDown(with: try key("\u{1b}", code: 53, in: window))
        try await waitUntil("Escape stops dictation") { !dictation.isSessionActive }
        #expect(input.string == "Keep these words")
        #expect(draft.text == input.string)

        dictation.toggle()
        try await waitUntil("dictation listens a third time") { dictation.phase == .listening }
        recognizer.send("Gone", isFinal: false)
        draft.text = "Replaced elsewhere"
        try await waitUntil("an outside draft change ends the session") { !dictation.isSessionActive }
        #expect(input.string == "Replaced elsewhere")
        #expect(draft.text == "Replaced elsewhere")
    }

    @Test func sendingWaitsForFinalWordsAndKeepsUnconfirmedWordsUnsent() async throws {
        let draft = ComposerDraft()
        let recognizer = ManualDictationRecognizer()
        var system = DictationSystem.manual(recognizer)
        system.finalizeTimeout = .milliseconds(150)
        let dictation = ComposerDictation(system: system)
        dictation.draftRevision = { draft.revision }
        let (window, input) = try await hostComposer(draft: draft, dictation: dictation)
        defer { window.close() }

        dictation.toggle()
        try await waitUntil("dictation listens") { dictation.phase == .listening }
        recognizer.send("Check the hed", isFinal: false)
        recognizer.finalWords = [("Check the header.", true)]
        #expect(await dictation.stop(.send))
        #expect(draft.text == "Check the header.")
        #expect(input.string == draft.text)
        #expect(dictation.notice == nil)

        dictation.toggle()
        try await waitUntil("dictation listens again") { dictation.phase == .listening }
        recognizer.send("And the footer", isFinal: false)
        recognizer.hangs = true
        #expect(await !dictation.stop(.send), "A stalled transcriber cannot confirm words for sending")
        #expect(draft.text == "Check the header. And the footer", "Unconfirmed words stay in the draft")
        #expect(dictation.notice == .unsent(revision: draft.revision))
        #expect(dictation.notice?.text == "Dictation didn't finish, so the message wasn't sent. Check the last words, then send.")
        #expect(!dictation.isSessionActive)

        dictation.draftChanged(to: draft.revision)
        #expect(dictation.notice != nil, "Committing the unconfirmed words is not an edit")
        input.setSelectedRange(NSRange(location: (input.string as NSString).length, length: 0))
        input.insertText(".", replacementRange: input.selectedRange())
        dictation.draftChanged(to: draft.revision)
        #expect(draft.text == "Check the header. And the footer.")
        #expect(dictation.notice == nil, "Editing the draft clears the notice")

        dictation.toggle()
        try await waitUntil("dictation listens a third time") { dictation.phase == .listening }
        recognizer.send("Thanks", isFinal: false)
        recognizer.hangs = true
        #expect(await !dictation.stop(.send))
        #expect(dictation.notice == .unsent(revision: draft.revision))
        dictation.draftSent()
        #expect(dictation.notice == nil, "Sending clears the notice")
    }

    @Test func silenceStopsDictationAndKeepsItsWords() async throws {
        #expect(DictationSystem.live.silenceTimeout == .seconds(30))
        let draft = ComposerDraft()
        let recognizer = ManualDictationRecognizer()
        var system = DictationSystem.manual(recognizer)
        system.silenceTimeout = .milliseconds(250)
        var announcements: [String] = []
        system.announce = { announcements.append($0) }
        let dictation = ComposerDictation(system: system)
        let (window, _) = try await hostComposer(draft: draft, dictation: dictation)
        defer { window.close() }
        // The words arrive as listening starts, so a busy main actor can't let silence win first.
        recognizer.firstWords = [("Quiet now", true)]
        dictation.toggle()
        try await waitUntil("silence stops dictation after its words") {
            draft.text == "Quiet now" && !dictation.isSessionActive
        }
        #expect(dictation.phase == .idle)
        #expect(announcements == ["Listening", "Dictation stopped"])
    }

    @Test func microphoneAccessStatesExplainThemselvesAndRecover() async throws {
        let access = MicrophoneAccessBox()
        var system = DictationSystem.scripted()
        system.microphoneAccess = { access.value }
        system.requestMicrophoneAccess = {
            access.requests += 1
            access.value = access.grants ? .granted : .denied
            return access.grants
        }
        var opened: [DictationAccess] = []
        system.openSettings = { opened.append($0) }
        let dictation = ComposerDictation(system: system)
        await dictation.refresh()
        #expect(dictation.availability == .available)
        #expect(dictation.accessOff == .microphone)
        dictation.toggle()
        #expect(dictation.showsAccessExplanation)
        #expect(dictation.phase == .idle)
        dictation.openSettings()
        #expect(opened == [.microphone])
        #expect(!dictation.showsAccessExplanation)
        #expect(DictationAccess.microphone.settingsURL?.absoluteString.hasSuffix("Privacy_Microphone") == true)

        access.value = .granted
        await dictation.refresh()
        #expect(dictation.accessOff == nil)

        access.value = .undetermined
        dictation.toggle()
        try await waitUntil("a declined prompt turns access off") { dictation.accessOff == .microphone }
        #expect(access.requests == 1)
        #expect(dictation.phase == .idle)

        dictation.system.hasMicrophone = { false }
        await dictation.refresh()
        #expect(dictation.availability == .noMicrophone)

        var unsupported = DictationSystem.scripted()
        unsupported.supportedLocale = { nil }
        let elsewhere = ComposerDictation(system: unsupported)
        await elsewhere.refresh()
        #expect(elsewhere.availability == .unsupported)
    }

    @Test func firstUseDownloadShowsProgressCancelsAndOnlyStartsInTheKeyWindow() async throws {
        let dictation = ComposerDictation(system: .scripted(downloadProgress: 0.35))
        await dictation.refresh()
        dictation.toggle()
        try await waitUntil("the download reports progress") { dictation.phase == .downloading(0.35) }
        #expect(dictation.notice?.text == "Downloading English dictation. This happens once.")
        dictation.toggle()
        #expect(dictation.phase == .idle)
        #expect(dictation.notice == nil)

        let recognizer = ManualDictationRecognizer()
        var system = DictationSystem.manual(recognizer)
        system.installAssets = { _, progress in
            progress(0.5)
            try await Task.sleep(for: .milliseconds(50))
            progress(1)
        }
        let target = RecordingDictationTarget()
        let downloaded = ComposerDictation(system: system)
        downloaded.target = target
        await downloaded.refresh()
        downloaded.toggle()
        try await waitUntil("the download finishes") { downloaded.phase == .idle && downloaded.notice == nil }
        #expect(target.begins == 0, "A finished download doesn't start listening in a background window")

        target.isInKeyWindow = true
        downloaded.toggle()
        try await waitUntil("listening starts in the key window") { downloaded.phase == .listening }
        #expect(target.begins == 1)
        downloaded.commitNow()
    }

    @Test func dictateAndAttachTakeClicksAcrossTheirWholeCircleNotJustTheGlyph() async throws {
        let dictation = ComposerDictation(system: .scripted())
        await dictation.refresh()
        var dictates = 0, attaches = 0
        // Offsets from the center that miss the glyph but fall inside the 28pt circle.
        let edges = [CGPoint(x: -12, y: 0), CGPoint(x: 0, y: 11), CGPoint(x: -8, y: -9), CGPoint(x: 9, y: 9)]
        let outside = CGPoint(x: -20, y: -20)
        for edge in edges {
            try await click(DictateButton(dictation: dictation) { dictates += 1 }, at: edge)
            try await click(AttachImagesButton { attaches += 1 }, at: edge)
        }
        try await click(DictateButton(dictation: dictation) { dictates += 1 }, at: outside)
        try await click(AttachImagesButton { attaches += 1 }, at: outside)
        #expect(dictates == edges.count)
        #expect(attaches == edges.count)
    }

    /// Clicks a point given as an offset from the center of a view hosted in its own window.
    private func click(_ button: some View, at offset: CGPoint) async throws {
        let size: CGFloat = 68
        let view = NSHostingView(rootView: button.frame(width: size, height: size))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let point = NSPoint(x: size / 2 + offset.x, y: size / 2 + offset.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    /// Whether SpeechAnalyzer's on-device English dictation model is installed. A failed inventory query
    /// throws rather than reading as a missing model.
    static func hasEnglishDictationModel() async throws -> Bool {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        else { return false }
        return try await AssetInventory.assetInstallationRequest(
            supporting: [DictationRecognizer.transcriber(for: locale)]) == nil
    }

    // GitHub's runners ship without the model, so CI skips this test. Locally it stays a requirement.
    @Test(.disabled("This CI runner has no on-device English (en_US) dictation model for SpeechAnalyzer") {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return false }
        return try await !ComposerTests.hasEnglishDictationModel()
    })
    func theRealTranscriberHearsARecordingThroughTheAudioSourceProtocol() async throws {
        guard try await Self.hasEnglishDictationModel() else {
            Issue.record("The on-device English dictation model is required for this test")
            return
        }
        let audio = try await speechFixture("Can you tighten the sidebar spacing? [[slnc 1500]] And check the header on the settings page.")
        defer { remove(audio) }
        let log = RecognizerLog()
        var stopsAfter: TimeInterval?
        var viewShowsUndraftedWords: () -> Bool = { false }
        var system = DictationSystem.live
        system.announce = { _ in }
        system.hasMicrophone = { true }
        system.microphoneAccess = { .granted }
        // Stops are explicit and finalizing always completes, so a busy machine can't end a session
        // between phrases or cut off its final words. The suite's time limit bounds both.
        system.silenceTimeout = .seconds(3_600)
        system.finalizeTimeout = .seconds(3_600)
        system.makeSource = { FileDictationSource(url: audio, stopsAfter: stopsAfter) }
        system.makeRecognizer = { locale, context, source in
            let recorder = RecordingRecognizer(
                DictationRecognizer(locale: locale, contextualStrings: context, source: source),
                viewShowsUndraftedWords: { viewShowsUndraftedWords() }
            )
            log.recognizers.append(recorder)
            return recorder
        }
        let draft = ComposerDraft()
        let dictation = ComposerDictation(system: system)
        let (window, input) = try await hostComposer(draft: draft, dictation: dictation)
        defer { window.close() }
        viewShowsUndraftedWords = { input.string != draft.text }

        // A full recording: tentative words show first, and phrases finalize at the pause.
        dictation.contextualStrings = ["Lead", "Everyone"]
        dictation.toggle()
        try await waitUntil("the transcriber hears the second phrase") {
            log.heard("settings", in: 0)
        }
        #expect(await dictation.stop())
        let full = log.recognizers[0]
        #expect(full.results.contains { !$0.isFinal }, "The transcriber reports tentative words")
        #expect(full.results.filter(\.isFinal).count >= 2, "Phrases finalize at the pause")
        #expect(full.results.contains { !$0.isFinal && $0.viewShowsUndraftedWords },
                "Tentative words show in the composer before the draft")
        let heard = draft.text.lowercased()
        for word in ["tighten", "sidebar", "header", "settings"] {
            #expect(heard.contains(word), "Heard \(draft.text)")
        }
        #expect(input.string == draft.text)

        // Stopped mid-phrase for Send: the final pass confirms the words before they're committed.
        // Clearing through the view keeps the view and draft in step without waiting for SwiftUI.
        input.selectAll(nil)
        input.delete(nil)
        #expect(draft.text.isEmpty)
        stopsAfter = 1.6
        dictation.toggle()
        try await waitUntil("the transcriber hears the clipped phrase") { log.heard("tighten", in: 1) }
        #expect(await dictation.stop(.send))
        #expect(log.recognizers.count == 2)
        let finals = log.recognizers[1].results.filter(\.isFinal).map(\.text)
        #expect(!finals.isEmpty)
        let committed = finals.reduce("") { DictationTranscript.join($0, $1) }
        #expect(draft.text == committed, "Only finalized words reach the draft: \(draft.text) vs \(committed)")
        #expect(draft.text.lowercased().contains("tighten"))
    }

    private func composerInput(in view: NSView) -> ComposerTextView? {
        if let input = view as? ComposerTextView { return input }
        for child in view.subviews {
            if let input = composerInput(in: child) { return input }
        }
        return nil
    }

    private func withDraft(_ body: (ComposerDraft, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-composer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { remove(directory) }
        let url = directory.appendingPathComponent("draft.json")
        try await body(ComposerDraft(fileURL: url), url)
    }

    private struct ComposerInputTestHost: View {
        @Bindable var draft: ComposerDraft
        var dictation: ComposerDictation? = nil
        @ViewState private var height: CGFloat = 44
        @ViewState private var focused = false
        @ViewState private var dragging = false
        private let focusRequest = UUID()

        var body: some View {
            NativeComposerInput(
                text: $draft.text, height: $height, focused: $focused, dragging: $dragging,
                fontSize: 14, focusRequest: focusRequest, agents: [.lead(id: "lead")], canManage: false,
                onSend: {}, onFiles: { _ in }, onImage: { _ in }, onError: { _ in },
                onCreate: { .init(id: "created", name: $0) }, onEdit: { _ in }, dictation: dictation
            )
            .frame(height: height)
        }
    }

    private func hostComposer(draft: ComposerDraft, dictation: ComposerDictation) async throws
        -> (window: NSWindow, input: ComposerTextView) {
        let host = NSHostingView(rootView: ComposerInputTestHost(draft: draft, dictation: dictation))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 140)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let input = try #require(composerInput(in: host))
        #expect(window.makeFirstResponder(input))
        await dictation.refresh()
        return (window, input)
    }

    /// Waits for observable state to satisfy `condition`, however long the shared main actor takes
    /// to get there. Each check runs when tracked state changes, and the suite's time limit ends a
    /// wait that never completes.
    private func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        while !condition() {
            guard !Task.isCancelled else {
                Issue.record("Gave up waiting until \(description)")
                throw CancellationError()
            }
            let change = ObservedChange()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    change.wait(continuation)
                    withObservationTracking { _ = condition() } onChange: { change.fire() }
                }
            } onCancel: {
                change.fire()
            }
        }
    }

    private func color(of input: NSTextView, at location: Int) -> NSColor? {
        input.textStorage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    private func key(_ characters: String, code: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    private func speechFixture(_ text: String) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-dictation-\(UUID()).aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, text]
        // Waiting without blocking keeps the main actor free for other suites while `say` renders.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            say.terminationHandler = { _ in continuation.resume() }
            do { try say.run() } catch { continuation.resume(throwing: error) }
        }
        try #require(say.terminationStatus == 0)
        return url
    }

    private func sampleImage() throws -> ComposerImage {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32
        ))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        return .init(name: "Sample.png", mimeType: "image/png", data: png)
    }

    private func finishLoading(_ draft: ComposerDraft) async throws {
        try await waitUntil("the images finish loading") { !draft.isLoadingImages }
    }

    private func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Composer test cleanup failed: \(error.localizedDescription)") }
    }
}

private extension DictationSystem {
    static func manual(_ recognizer: ManualDictationRecognizer) -> DictationSystem {
        var system = DictationSystem.scripted()
        system.makeRecognizer = { _, _, _ in recognizer }
        return system
    }
}

/// Delivers results when the test says so, and finalizes or stalls on demand.
@MainActor private final class ManualDictationRecognizer: DictationRecognizing {
    /// Heard the moment listening starts, before any timer can run.
    var firstWords: [(String, Bool)] = []
    var finalWords: [(String, Bool)] = []
    var hangs = false
    private(set) var isCancelled = false
    private var onResult: (@MainActor (String, Bool) -> Void)?

    func start(onListening: @escaping @MainActor () -> Void,
               onResult: @escaping @MainActor (String, Bool) -> Void,
               onLevel: @escaping @MainActor @Sendable (Double) -> Void,
               onInterruption: @escaping @MainActor @Sendable () -> Void,
               onFailure: @escaping @MainActor (any Error) -> Void) async throws {
        isCancelled = false
        hangs = false
        finalWords = []
        self.onResult = onResult
        onListening()
        for (text, isFinal) in firstWords { onResult(text, isFinal) }
    }

    func send(_ text: String, isFinal: Bool) { onResult?(text, isFinal) }

    func finish() async throws {
        while hangs && !isCancelled { try await Task.sleep(for: .milliseconds(10)) }
        if isCancelled { throw CancellationError() }
        for (text, isFinal) in finalWords { onResult?(text, isFinal) }
    }

    func cancel() { isCancelled = true }
}

/// Wraps the real recognizer and records every result it reports, with whether the composer was
/// showing words the draft didn't have yet once the model had handled it.
@MainActor @Observable private final class RecordingRecognizer: DictationRecognizing {
    @ObservationIgnored private let inner: any DictationRecognizing
    @ObservationIgnored private let viewShowsUndraftedWords: () -> Bool
    private(set) var results: [(text: String, isFinal: Bool, viewShowsUndraftedWords: Bool)] = []

    init(_ inner: any DictationRecognizing, viewShowsUndraftedWords: @escaping () -> Bool) {
        self.inner = inner
        self.viewShowsUndraftedWords = viewShowsUndraftedWords
    }

    func start(onListening: @escaping @MainActor () -> Void,
               onResult: @escaping @MainActor (String, Bool) -> Void,
               onLevel: @escaping @MainActor @Sendable (Double) -> Void,
               onInterruption: @escaping @MainActor @Sendable () -> Void,
               onFailure: @escaping @MainActor (any Error) -> Void) async throws {
        try await inner.start(onListening: onListening, onResult: { [weak self] text, isFinal in
            onResult(text, isFinal)
            guard let self else { return }
            results.append((text, isFinal, viewShowsUndraftedWords()))
        }, onLevel: onLevel, onInterruption: onInterruption, onFailure: onFailure)
    }

    func finish() async throws { try await inner.finish() }
    func cancel() { inner.cancel() }
}

/// Every recognizer a session made, observable so tests can wait for what each one heard.
@MainActor @Observable private final class RecognizerLog {
    var recognizers: [RecordingRecognizer] = []

    func heard(_ word: String, in session: Int) -> Bool {
        recognizers.indices.contains(session)
            && recognizers[session].results.contains { $0.text.localizedCaseInsensitiveContains(word) }
    }
}

/// Resumes one observation wait, whether the observed state changed or the test was cancelled.
private final class ObservedChange: Sendable {
    private let state = Mutex<(fired: Bool, continuation: CheckedContinuation<Void, Never>?)>((false, nil))

    func wait(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = state.withLock { state in
            if state.fired { return true }
            state.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func fire() {
        state.withLock { state in
            state.fired = true
            defer { state.continuation = nil }
            return state.continuation
        }?.resume()
    }
}

@MainActor private final class RecordingDictationTarget: DictationTextTarget {
    var isInKeyWindow = false
    private(set) var begins = 0

    func beginDictation() -> Bool {
        begins += 1
        return true
    }

    func showDictation(_ transcript: DictationTranscript) {}
    func endDictation(_ finalized: String) {}
}

@MainActor private final class MicrophoneAccessBox {
    var value = DictationMicrophoneAccess.denied
    var grants = false
    var requests = 0
}
