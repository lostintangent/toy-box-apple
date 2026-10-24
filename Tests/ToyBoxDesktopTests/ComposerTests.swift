import AppKit
import AVFoundation
@testable import ChannelClient
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
        #expect(key == "7666436268910164a35f2ac26b9f08b3bf3ebed835c132e3d2c6e8984549822e")
        #expect(key == ComposerDraft.storageKey(serverURL: normalized, channelID: "channel"))
        #expect(key != ComposerDraft.storageKey(serverURL: otherServer, channelID: "channel"))
        #expect(key != ComposerDraft.storageKey(serverURL: normalized, channelID: "another"))
        let quickAsk = ComposerDraft.storageKey(serverURL: normalized, channelID: "channel", scope: .quickAsk)
        let reply = ComposerDraft.storageKey(serverURL: normalized, channelID: "channel", scope: .inboxReply(sequence: 8))
        #expect(Set([key, quickAsk, reply]).count == 3)
        #expect(reply != ComposerDraft.storageKey(serverURL: normalized, channelID: "channel",
                                                scope: .inboxReply(sequence: 9)))
        #expect(quickAsk == ComposerDraft.storageKey(serverURL: upper, channelID: "channel", scope: .quickAsk))
    }

    @Test func auxiliaryRepliesSeedOnceAndKeepStaleRequestsUnsent() async throws {
        try await withDraft { draft, url in
            let store = ChannelStore(id: "test", api: try ChannelAPI(serverURL: "http://localhost:3210"),
                                     sendJournal: nil)
            let channel = Channel(id: "test", name: "Test", model: .init(provider: "test", name: "test"),
                                  requestSequence: 8, updatedAt: "2026-10-24T00:00:00Z")
            let initial = ChannelState(revision: 1, channel: channel, lead: .lead(id: "lead"))
            _ = try store.apply(.init(type: "snapshot", state: initial))
            let session = AuxiliaryComposerSession(store: store, scope: .inboxReply(sequence: 8),
                                                   requester: .init(id: "ada", name: "Ada Lovelace"), draft: draft)
            #expect(draft.text == "@ada-lovelace ")
            #expect(session.canSend)
            #expect(!session.requestChanged)
            #expect(store.state?.channel.seenThrough == 0)
            session.invalidateRequest()
            #expect(session.requestChanged)
            #expect(!session.canSend)
            draft.text = ""
            let restored = ComposerDraft(fileURL: url)
            let reopened = AuxiliaryComposerSession(store: store, scope: .inboxReply(sequence: 8),
                                                    requester: .init(id: "ada", name: "Ada Lovelace"), draft: restored)
            #expect(reopened.draft.text.isEmpty)
            draft.text = "Keep this reply"
            var changed = initial
            changed.revision = 2
            changed.channel.requestSequence = 9
            _ = try store.apply(.init(type: "snapshot", state: changed))
            #expect(session.requestChanged)
            #expect(!session.canSend)
            await session.send()
            #expect(draft.text == "Keep this reply")
            #expect(draft.sendAttemptID == nil)
            #expect(store.sendAttempts.isEmpty)
            #expect(session.error?.contains("request changed") == true)
            #expect(store.state?.channel.seenThrough == 0)
        }
    }

    @Test func quickAskRestoresDraftTargetsBeforeRecentsAndNeverGuessesAmongChannels() throws {
        let suite = "ComposerQuickAsk-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = try #require(URL(string: "http://localhost:3210"))
        let alpha = Channel(id: "alpha", name: "Alpha", purpose: "Build the launch",
                            model: .init(provider: "test", name: "test"), updatedAt: "2026-10-24T00:00:00Z")
        var beta = alpha
        beta.id = "beta"; beta.name = "Beta"; beta.purpose = "Sketch the entrance"
        let history = QuickAskTargetHistory(serverURL: server, defaults: defaults)
        #expect(history.initialTarget(channels: [beta, alpha], lastUsedID: nil, hasDraft: { _ in false }) == nil)
        #expect(history.initialTarget(channels: [beta, alpha], lastUsedID: "alpha", hasDraft: { _ in false }) == "alpha")
        #expect(history.initialTarget(channels: [beta], lastUsedID: nil, hasDraft: { _ in false }) == "beta")
        history.choose(beta)
        #expect(history.initialTarget(channels: [beta, alpha], lastUsedID: "alpha", hasDraft: { _ in false }) == "beta")
        history.trackDraft(channelID: "alpha", name: "Alpha", hasContent: true)
        let restored = QuickAskTargetHistory(serverURL: server, defaults: defaults)
        #expect(restored.initialTarget(channels: [beta], lastUsedID: "beta", hasDraft: { $0 == "alpha" }) == "alpha")
        #expect(restored.choices(channels: [alpha, beta], query: "").map(\.id) == ["beta", "alpha"])
        #expect(restored.choices(channels: [alpha, beta], query: "entrance").map(\.id) == ["beta"])
        #expect(restored.choices(channels: [alpha, beta], query: "LAUNCH").map(\.id) == ["alpha"])
        restored.trackDraft(channelID: "alpha", name: nil, hasContent: false)
        #expect(restored.initialTarget(channels: [alpha], lastUsedID: "alpha", hasDraft: { _ in false }) == nil)
        let otherServer = QuickAskTargetHistory(serverURL: try #require(URL(string: "http://localhost:3211")),
                                               defaults: defaults)
        #expect(otherServer.initialTarget(channels: [alpha, beta], lastUsedID: nil, hasDraft: { _ in false }) == nil)
    }

    @Test(arguments: [422, 503])
    func auxiliarySendAgainUsesTheSharedOutboxAndOriginalImmutableMessage(status: Int) async throws {
        try await withDraft { draft, _ in
            let host = UUID().uuidString.lowercased() + ".invalid"
            AuxiliaryPostProtocol.fixtures.withLock { $0[host] = .init(statuses: [status, 201]) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AuxiliaryPostProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer {
                transport.invalidateAndCancel()
                AuxiliaryPostProtocol.fixtures.withLock { _ = $0.removeValue(forKey: host) }
            }
            let store = ChannelStore(id: "test", api: try ChannelAPI(serverURL: "http://\(host)", session: transport),
                                     sendJournal: nil)
            let channel = Channel(id: "test", name: "Test", model: .init(provider: "test", name: "test"),
                                  updatedAt: "2026-10-24T00:00:00Z")
            _ = try store.apply(.init(type: "snapshot", state: .init(revision: 1, channel: channel,
                                                                    lead: .lead(id: "lead"))))
            draft.text = "Original message"
            draft.append(try sampleImage())
            let session = AuxiliaryComposerSession(store: store, scope: .quickAsk, draft: draft)
            await session.send(opensChannel: true)
            let originalID = try #require(draft.sendAttemptID)
            #expect(session.confirmation == nil)
            #expect(session.isReadOnly)
            #expect(session.attempt?.phase == (status == 422 ? .notSent : .deliveryNotConfirmed))
            #expect(session.deliveryNotice?.contains(status == 422 ? "Rejected" : "It may have arrived") == true)
            #expect(draft.text == "Original message")
            #expect(draft.images.count == 1)
            #expect(AuxiliaryPostProtocol.fixtures.withLock { $0[host]?.posts.count } == 1)
            await session.send()
            #expect(session.confirmation?.id == originalID)
            #expect(session.confirmation?.sequence == 7)
            #expect(session.confirmation?.opensChannel == false)
            #expect(!draft.hasContent)
            #expect(store.sendAttempts.isEmpty)
            #expect(store.state?.channel.seenThrough == 0)
            let posts = AuxiliaryPostProtocol.fixtures.withLock { $0[host]?.posts ?? [] }
            #expect(posts.count == 2)
            #expect(posts.first == posts.last)
            #expect(posts.first?.id == originalID)
            #expect(posts.first?.attachments?.count == 1)
        }
    }

    @Test func auxiliaryEchoConfirmationClearsOnlyItsOwnUnchangedDraft() async throws {
        try await withDraft { draft, _ in
            let store = ChannelStore(id: "test", api: try ChannelAPI(serverURL: "http://localhost:3210"),
                                     sendJournal: nil)
            draft.text = "An unconfirmed message"
            draft.associateSend(id: "original")
            let session = AuxiliaryComposerSession(store: store, scope: .quickAsk, draft: draft)
            #expect(session.isReadOnly)
            #expect(session.deliveryNotice == "Delivery not confirmed. It may have arrived.")
            let message = ChannelMessage(id: "original", sequence: 9, timestamp: "2026-10-24T00:00:00Z",
                                         sender: .user, content: .text(draft.text))
            let channel = Channel(id: "test", name: "Test", model: .init(provider: "test", name: "test"),
                                  latestSequence: 9, updatedAt: message.timestamp)
            let state = ChannelState(revision: 2, channel: channel, lead: .lead(id: "lead"), messages: [message])
            _ = try store.apply(.init(type: "snapshot", state: state))
            session.reconcileDelivery()
            #expect(session.confirmation?.id == "original")
            #expect(session.confirmation?.sequence == 9)
            #expect(!draft.hasContent)
            #expect(draft.sendAttemptID == nil)
            session.beginPresentation()
            #expect(session.confirmation == nil)
            draft.text = "A different unconfirmed message"
            draft.associateSend(id: "second")
            let editedSession = AuxiliaryComposerSession(store: store, scope: .quickAsk, draft: draft)
            editedSession.edit()
            #expect(editedSession.editedUnconfirmedMessage)
            #expect(draft.sendAttemptID == nil)
            draft.text = "A newer draft"
            var second = message
            second.id = "second"
            var updated = state
            updated.revision = 3
            updated.messages.append(second)
            _ = try store.apply(.init(type: "snapshot", state: updated))
            editedSession.reconcileDelivery()
            #expect(draft.text == "A newer draft")
            #expect(editedSession.confirmation == nil)
        }
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

    @Test func nativeEditingKeepsNewlinesUndoAndAccessibilityEditsButOnlyReturnSends() throws {
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
        #expect(input.selectedRange() == NSRange(location: text.utf16.count, length: 0))

        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        input.setAccessibilityValue("Accessible edit")
        #expect(input.string == "Accessible edit")
        #expect(text == input.string)

        #expect(try coordinator.handle(key("\r", code: 36, in: window)))
        #expect(try coordinator.handle(key("\r", code: 36, in: window, modifiers: .command)))
        #expect(sends == 2)
        #expect(try !coordinator.handle(key("\r", code: 36, in: window, modifiers: .shift)))
        input.setMarkedText("\u{5019}\u{88dc}", selectedRange: .init(location: 2, length: 0),
                            replacementRange: .init(location: NSNotFound, length: 0))
        #expect(input.hasMarkedText())
        #expect(try !coordinator.handle(key("\r", code: 36, in: window)))
        #expect(sends == 2)
        input.unmarkText()
        var sendsAndOpen = 0
        var dismissals = 0
        coordinator.parent.onSendAndOpen = { sendsAndOpen += 1 }
        coordinator.parent.onEscape = { dismissals += 1 }
        #expect(try coordinator.handle(key("\r", code: 36, in: window, modifiers: .command)))
        #expect(try coordinator.handle(key("\u{1b}", code: 53, in: window)))
        #expect(sendsAndOpen == 1)
        #expect(dismissals == 1)
        #expect(sends == 2)
        coordinator.parent.isEditable = false
        #expect(try coordinator.handle(key("\r", code: 36, in: window, modifiers: .command)))
        #expect(sendsAndOpen == 1)
    }

    @Test func pasteboardImagesAndFilesUseTheSameImportCallbacks() throws {
        var images: [ComposerImage] = []
        var files: [URL] = []
        var errors: [String] = []
        let parent = NativeComposerInput(
            text: .constant(""), height: .constant(44), focused: .constant(false),
            dragging: .constant(false), fontSize: 14, focusRequest: UUID(),
            agents: [], canManage: false, onSend: {}, onFiles: { files += $0 },
            onImage: { images.append($0) }, onError: { errors.append($0) },
            onCreate: { .init(id: "created", name: $0) }, onEdit: { _ in }
        )
        let coordinator = parent.makeCoordinator()
        let input = ComposerTextView()
        input.isRichText = false
        input.importsGraphics = false
        input.coordinator = coordinator
        let pasteboard = NSPasteboard.withUniqueName()
        input.attachmentPasteboard = pasteboard
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        defer { pasteboard.releaseGlobally() }
        let image = try sampleImage()
        #expect(pasteboard.setData(image.data, forType: .png))
        #expect(input.validateMenuItem(paste))
        input.paste(nil)
        #expect(images.first?.data == image.data)
        #expect(images.first?.mimeType == "image/png")
        pasteboard.clearContents()
        let file = URL(fileURLWithPath: "/tmp/composer-pasteboard-fixture.png")
        #expect(pasteboard.writeObjects([file as NSURL]))
        #expect(input.validateMenuItem(paste))
        #expect(coordinator.acceptPasteboard(pasteboard))
        #expect(files == [file])
        #expect(images.count == 1)
        pasteboard.clearContents()
        #expect(pasteboard.setString("Ordinary text", forType: .string))
        #expect(!coordinator.canAcceptPasteboard(pasteboard))
        #expect(!coordinator.acceptPasteboard(pasteboard))
        let tiff = try #require(image.image?.tiffRepresentation)
        pasteboard.declareTypes([.tiff, .png], owner: nil)
        #expect(pasteboard.setData(tiff, forType: .tiff))
        #expect(pasteboard.setData(image.data, forType: .png))
        #expect(coordinator.acceptPasteboard(pasteboard))
        #expect(images.last?.data == image.data)
        #expect(images.last?.mimeType == "image/png")
        pasteboard.declareTypes([.tiff], owner: nil)
        #expect(pasteboard.setData(tiff, forType: .tiff))
        #expect(input.validateMenuItem(paste))
        input.paste(nil)
        #expect(images.last?.mimeType == "image/png")
        #expect(images.last?.image != nil)
        pasteboard.declareTypes([.string, .tiff, .png], owner: nil)
        #expect(pasteboard.setString("Copied spreadsheet cells", forType: .string))
        #expect(pasteboard.setData(tiff, forType: .tiff))
        #expect(pasteboard.setData(image.data, forType: .png))
        #expect(!coordinator.canAcceptPasteboard(pasteboard))
        #expect(!coordinator.acceptPasteboard(pasteboard))
        #expect(images.count == 3)
        pasteboard.declareTypes([.tiff, .string], owner: nil)
        #expect(pasteboard.setData(tiff, forType: .tiff))
        #expect(pasteboard.setString("Image description", forType: .string))
        #expect(coordinator.canAcceptPasteboard(pasteboard))
        #expect(coordinator.acceptPasteboard(pasteboard))
        #expect(images.count == 4)
        input.isEditable = false
        #expect(!input.validateMenuItem(paste))
        input.paste(nil)
        pasteboard.declareTypes([.png], owner: nil)
        #expect(pasteboard.setData(Data([1, 2, 3]), forType: .png))
        #expect(coordinator.acceptPasteboard(pasteboard))
        #expect(errors.count == 1)
        #expect(errors.first?.contains("could not be read") == true)
        #expect(images.count == 4)
    }

    @Test func tabLeavesTheComposerLikeATextareaUnlessItAcceptsAMention() async throws {
        let draft = ComposerDraft()
        // AppKit neighbors keep these focus moves out of SwiftUI's focus state, which tests running
        // alongside this one rely on to focus their own fields.
        let before = NSTextField(frame: NSRect(x: 0, y: 190, width: 400, height: 22))
        before.placeholderString = "Before"
        let after = NSTextField(frame: NSRect(x: 0, y: 8, width: 400, height: 22))
        after.placeholderString = "After"
        // Fixed frames, with no sizing constraints from the host. In an autolayout container, each
        // move of the host invalidated its safe area, and CI's display cycle looped on that until
        // AppKit threw.
        let host = NSHostingView(rootView: ComposerInputTestHost(draft: draft))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 40, width: 400, height: 140)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        [before, host, after].forEach(container.addSubview)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        // The mention popover only shows from an ordered-in window, so keep it out of sight.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer {
            // Resigning closes any open mention popover before the window goes.
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.close()
        }
        try await waitForUpdate(of: container, "the composer mounts") { composerInput(in: container) != nil }
        let input = try #require(composerInput(in: container))
        func press(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
            input.keyDown(with: try key(characters, code: keyCode, in: window, modifiers: modifiers))
        }
        func type(_ text: String) async throws {
            #expect(window.makeFirstResponder(input))
            input.string = ""
            input.insertText(text, replacementRange: input.selectedRange())
            try await waitForUpdate(of: host, "the text and mention menu update") {
                draft.text == text && input.coordinator?.isCompletionVisible == (text == "@")
            }
        }
        var focusedField: String? {
            let responder: AnyObject? = (window.firstResponder as? NSText)?.delegate ?? window.firstResponder
            return (responder as? NSTextField)?.placeholderString
        }

        try await type("Hello")
        try press(48, "\t")
        #expect(focusedField == "After")
        try await type("Hello")
        try press(48, "\u{19}", .shift)
        #expect(focusedField == "Before")
        #expect(draft.text == "Hello")
        try await type("Hello")
        try press(48, "\t", .option)
        #expect(window.firstResponder === input)
        #expect(draft.text == "Hello\t")

        // With the mention list open, Tab accepts like Return. Shift still moves back, as in the pane,
        // and Option-Tab is still a literal tab.
        try await type("@")
        try press(125, "\u{f701}")
        try press(48, "\t")
        #expect(window.firstResponder === input)
        #expect(draft.text == "@lead ")
        try await type("@")
        try press(48, "\u{19}", .shift)
        #expect(focusedField == "Before")
        #expect(draft.text == "@")
        try await type("@")
        try press(48, "\t", .option)
        #expect(window.firstResponder === input)
        #expect(draft.text == "@\t")
        try await type("@")
        try press(36, "\r", .shift)
        #expect(draft.text == "@\n")
        // The new line ends the mention, so Return sends rather than accepting one.
        try press(36, "\r")
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
        for (index, character) in ["a", "b", "c"].enumerated() {
            let pendingText = draft.text + character
            input.string = pendingText
            input.setSelectedRange(NSRange(location: pendingText.utf16.count, length: 0))
            coordinator.synchronizeModelText(draft.text)
            #expect(input.string == "Seed" + String("abc".prefix(index + 1)))
            #expect(input.selectedRange() == NSRange(location: pendingText.utf16.count, length: 0))
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
            #expect(draft.text == pendingText)
        }
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
        let artifact = ChannelArtifact(file: .init(kind: "machine", path: "/tmp/plan.md"), title: "Plan")
        #expect(!ComposerTray.isVisible(artifacts: [], tasks: [], preview: nil))
        #expect(ComposerTray.isVisible(artifacts: [artifact], tasks: [], preview: nil))
        #expect(ComposerTray.isVisible(artifacts: [], tasks: [.init(id: "task", title: "Task")], preview: nil))
        #expect(ComposerTray.isVisible(artifacts: [], tasks: [], preview: .init(kind: "screen", screenId: "main")))
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
            try await waitForUpdate(of: view, "the overflowing strip scrolls sideways") {
                if scrollView.contentView.bounds.minX > 0 { return true }
                let notch = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                                 wheel1: 0, wheel2: -3, wheel3: 0))
                scrollView.scrollWheel(with: try #require(NSEvent(cgEvent: notch)))
                return scrollView.contentView.bounds.minX > 0
            }
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

    @Test func switchingDraftsKeepsTheTextViewAndLeavesEachDraftItsOwnWordsAndUndo() async throws {
        let first = ComposerDraft()
        let second = ComposerDraft()
        let secondText = "One\nTwo\nThree\nFour\nSecond channel draft"
        second.text = secondText
        let recognizer = ManualDictationRecognizer()
        let dictation = ComposerDictation(system: .manual(recognizer))
        let shown = ShownDraft(first)
        let host = NSHostingView(rootView: ComposerSwitchTestHost(shown: shown, dictation: dictation))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 140)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await waitForUpdate(of: host, "the composer mounts") { composerInput(in: host) != nil }
        let input = try #require(composerInput(in: host))
        let clip = try #require(input.enclosingScrollView?.contentView)
        #expect(window.makeFirstResponder(input))
        await dictation.refresh()

        input.insertText("Typed here", replacementRange: input.selectedRange())
        #expect(first.text == "Typed here")
        dictation.toggle()
        try await waitUntil("dictation listens") { dictation.phase == .listening }
        recognizer.send("and spoken", isFinal: false)
        #expect(input.string == "Typed here and spoken")

        shown.draft = second
        try await waitUntil("the switch commits dictation") { !dictation.isSessionActive }
        #expect(composerInput(in: host) === input, "The switch keeps the text view")
        #expect(first.text == "Typed here and spoken", "Spoken words stay with the draft they were spoken into")
        #expect(second.text == secondText)
        #expect(input.string == secondText)
        #expect(color(of: input, at: 0) == .textColor)
        #expect(input.selectedRange() == NSRange(location: secondText.utf16.count, length: 0), "The caret starts at the end")
        #expect(input.undoManager?.canUndo == false, "Undo never reaches into another draft")
        try await waitForUpdate(of: host, "the composer grows to three lines") { clip.frame.height > 80 }
        #expect(abs(clip.bounds.maxY - input.frame.maxY) < 1, "The caret's last line is in view")

        input.insertText("!", replacementRange: input.selectedRange())
        #expect(second.text == secondText + "!")
        #expect(first.text == "Typed here and spoken")

        shown.draft = first
        try await waitForUpdate(of: host, "the first draft returns") { input.string == first.text }
        #expect(composerInput(in: host) === input)
        #expect(input.selectedRange() == NSRange(location: 21, length: 0))
        #expect(input.undoManager?.canUndo == false)
        try await waitForUpdate(of: host, "the composer shrinks to one line") { clip.frame.height < 50 }
        #expect(clip.bounds.minY == 0, "A one-line draft isn't left scrolled")
        #expect(second.text == secondText + "!")
    }

    /// Every switch reconnects the channel it shows, so a quick connect mustn't flash the reason Send is off.
    @Test func aBriefConnectDoesNotFlashWhySendIsOff() async {
        let grace = ConnectGrace()
        grace.duration = .milliseconds(100)
        let first = ComposerDraft()
        let second = ComposerDraft()
        let shown = ObjectIdentifier(first)
        #expect(grace.explains(.stale(message: "Offline", retryAt: .now), for: shown))
        #expect(grace.explains(.deleted, for: shown))
        #expect(!grace.explains(.live, for: shown))
        #expect(!grace.explains(.idle, for: shown), "A switch shows the channel before it connects")
        #expect(!grace.explains(.connecting, for: shown), "A connect starts without the explanation")

        let finished = Task { await grace.watch(.connecting, for: shown) }
        finished.cancel()
        await finished.value
        #expect(!grace.explains(.connecting, for: shown), "A connect that finishes in time never explains")

        let started = ContinuousClock.now
        await grace.watch(.connecting, for: shown)
        #expect(ContinuousClock.now - started >= .milliseconds(100))
        #expect(grace.explains(.connecting, for: shown), "A slow connect explains")
        #expect(!grace.explains(.connecting, for: ObjectIdentifier(second)),
                "Another channel's slow connect doesn't carry over")

        await grace.watch(.live, for: shown)
        #expect(!grace.explains(.connecting, for: shown), "The next connect starts quiet again")
        await grace.watch(.idle, for: shown)
        #expect(grace.explains(.idle, for: shown), "A channel that never starts connecting explains")
        await grace.watch(.connecting, for: shown)
        grace.reset()
        #expect(!grace.explains(.connecting, for: shown), "A switch starts quiet before its first frame")
    }

    @Test func sendingWaitsForFinalWordsAndKeepsUnconfirmedWordsUnsent() async throws {
        var revision = UUID()
        let recognizer = ManualDictationRecognizer()
        var system = DictationSystem.manual(recognizer)
        system.finalizeTimeout = .milliseconds(150)
        let dictation = ComposerDictation(system: system)
        let target = RecordingDictationTarget()
        dictation.target = target
        dictation.draftRevision = { revision }
        await dictation.refresh()
        defer { dictation.deactivate() }

        dictation.toggle()
        try await waitUntil("dictation listens") { dictation.phase == .listening }
        recognizer.send("Check the hed", isFinal: false)
        recognizer.finalWords = [("Check the header.", true)]
        #expect(await dictation.stop(.send))
        #expect(target.commits == ["Check the header."])
        #expect(dictation.notice == nil)

        dictation.toggle()
        try await waitUntil("dictation listens again") { dictation.phase == .listening }
        recognizer.send("And the footer", isFinal: false)
        recognizer.hangs = true
        #expect(await !dictation.stop(.send), "A stalled transcriber cannot confirm words for sending")
        #expect(target.commits == ["Check the header.", "And the footer"], "Unconfirmed words reach the text target")
        #expect(dictation.notice == .unsent(revision: revision))
        #expect(dictation.notice?.text == "Dictation didn't finish, so the message wasn't sent. Check the last words, then send.")
        #expect(!dictation.isSessionActive)

        dictation.draftChanged(to: revision)
        #expect(dictation.notice != nil, "Committing the unconfirmed words is not an edit")
        revision = UUID()
        dictation.draftChanged(to: revision)
        #expect(dictation.notice == nil, "Editing the draft clears the notice")

        dictation.toggle()
        try await waitUntil("dictation listens a third time") { dictation.phase == .listening }
        recognizer.send("Thanks", isFinal: false)
        recognizer.hangs = true
        #expect(await !dictation.stop(.send))
        #expect(dictation.notice == .unsent(revision: revision))
        dictation.draftSent()
        #expect(dictation.notice == nil, "Sending clears the notice")
    }

    @Test func silenceStopsDictationAndKeepsItsWords() async throws {
        #expect(DictationSystem.live.silenceTimeout == .seconds(30))
        let recognizer = ManualDictationRecognizer()
        var system = DictationSystem.manual(recognizer)
        system.silenceTimeout = .milliseconds(250)
        var announcements: [String] = []
        system.announce = { announcements.append($0) }
        let dictation = ComposerDictation(system: system)
        let target = RecordingDictationTarget()
        dictation.target = target
        await dictation.refresh()
        defer { dictation.deactivate() }
        // The words arrive as listening starts, so a busy main actor can't let silence win first.
        recognizer.firstWords = [("Quiet now", true)]
        dictation.toggle()
        try await waitUntil("silence stops dictation after its words") {
            target.commits == ["Quiet now"] && !dictation.isSessionActive
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
        #expect(dictation.accessOff == nil, "Access waits for the first click")
        dictation.toggle()
        try await waitUntil("the first click finds access off") { dictation.showsAccessExplanation }
        #expect(dictation.accessOff == .microphone)
        #expect(dictation.phase == .idle)
        dictation.showsAccessExplanation = false
        dictation.toggle()
        #expect(dictation.showsAccessExplanation, "Later clicks explain at once")
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

    @Test func theMicrophoneAndItsAccessWaitForTheFirstClick() async throws {
        let probe = MicrophoneProbe()
        var system = DictationSystem.scripted()
        system.hasMicrophone = {
            probe.deviceChecks += 1
            return probe.isConnected
        }
        system.microphoneAccess = {
            probe.accessChecks += 1
            return .granted
        }
        var announcements: [String] = []
        system.announce = { announcements.append($0) }
        let dictation = ComposerDictation(system: system)
        dictation.activate()
        defer { dictation.deactivate() }
        try await waitUntil("the language check finishes") { dictation.availability != .checking }
        await dictation.refresh()
        #expect(probe.deviceChecks == 0, "Finding the input device starts Core Audio, so activating never does")
        #expect(probe.accessChecks == 0)
        #expect(dictation.availability == .available, "Dictate shows before anything looks for a microphone")

        dictation.toggle()
        try await waitUntil("the first click finds no microphone") { dictation.notice == .noMicrophone }
        #expect(dictation.availability == .noMicrophone)
        #expect(dictation.phase == .idle)
        #expect(dictation.notice?.text == "Connect a microphone to dictate.")
        #expect(announcements == ["Connect a microphone to dictate."])
        #expect(probe.deviceChecks == 1)

        probe.isConnected = true
        NotificationCenter.default.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
        try await waitUntil("connecting a microphone enables Dictate") { dictation.availability == .available }
        #expect(dictation.notice == nil)
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
        let size: CGFloat = 68
        let view = NSHostingView(rootView: HStack(spacing: 0) {
            DictateButton(dictation: dictation) { dictates += 1 }.frame(width: size, height: size)
            AttachImagesButton { attaches += 1 }.frame(width: size, height: size)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size * 2, height: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.close() }
        try await waitForUpdate(of: view, "both native buttons mount") {
            func countButtons(in view: NSView) -> Int {
                (view is NSButton ? 1 : 0) + view.subviews.reduce(0) { $0 + countButtons(in: $1) }
            }
            return countButtons(in: view) == 2
        }
        let edges = [CGPoint(x: -12, y: 0), CGPoint(x: 0, y: 11), CGPoint(x: -8, y: -9), CGPoint(x: 9, y: 9)]
        for offset in edges + [CGPoint(x: -20, y: -20)] {
            for centerX in [size / 2, size * 1.5] {
                let point = NSPoint(x: centerX + offset.x, y: size / 2 + offset.y)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
            }
        }
        #expect(dictates == edges.count)
        #expect(attaches == edges.count)
    }

    /// Whether SpeechAnalyzer's on-device English dictation model is installed. A failed inventory query
    /// throws rather than reading as a missing model.
    static func hasEnglishDictationModel() async throws -> Bool {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        else { return false }
        return try await AssetInventory.assetInstallationRequest(
            supporting: [DictationRecognizer.transcriber(for: locale)]) == nil
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOY_BOX_REAL_DICTATION_TESTS"] == "1",
                   "Opt in with TOY_BOX_REAL_DICTATION_TESTS=1 and an installed English dictation model"))
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
                text: $draft.text, document: ObjectIdentifier(draft), height: $height, focused: $focused,
                dragging: $dragging, fontSize: 14, focusRequest: focusRequest, agents: [.lead(id: "lead")],
                canManage: false, onSend: {}, onFiles: { _ in }, onImage: { _ in }, onError: { _ in },
                onCreate: { .init(id: "created", name: $0) }, onEdit: { _ in }, dictation: dictation
            )
            .frame(height: height)
        }
    }

    /// Like a window switching channels, one composer that the shown draft passes through.
    private struct ComposerSwitchTestHost: View {
        let shown: ShownDraft
        let dictation: ComposerDictation

        var body: some View { ComposerInputTestHost(draft: shown.draft, dictation: dictation) }
    }


    private func hostComposer(draft: ComposerDraft, dictation: ComposerDictation) async throws
        -> (window: NSWindow, input: ComposerTextView) {
        let host = NSHostingView(rootView: ComposerInputTestHost(draft: draft, dictation: dictation))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 140)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        try await waitForUpdate(of: host, "the composer mounts") { composerInput(in: host) != nil }
        let input = try #require(composerInput(in: host))
        #expect(window.makeFirstResponder(input))
        await dictation.refresh()
        return (window, input)
    }

    private func waitUntil(_ description: String, _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while try !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = try condition()
        try #require(satisfied, "Timed out waiting until \(description)")
    }

    /// Waits for SwiftUI to update a hosted AppKit view, for checks on state that isn't observable.
    private func waitForUpdate(of host: NSView, _ description: String, until condition: () throws -> Bool) async throws {
        try await waitUntil(description) {
            host.layoutSubtreeIfNeeded()
            return try condition()
        }
    }

    private func color(of input: NSTextView, at location: Int) -> NSColor? {
        input.textStorage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    private func key(_ characters: String, code: UInt16, in window: NSWindow,
                     modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
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

private final class AuxiliaryPostProtocol: URLProtocol, @unchecked Sendable {
    struct Posted: Codable, Equatable, Sendable {
        let id: String
        let content: String
        let attachments: [ChannelAttachment]?
    }
    struct Fixture: Sendable {
        var statuses: [Int]
        var posts: [Posted] = []
    }
    private struct Envelope: Encodable {
        let version = 1
        let message: ChannelMessage
    }
    static let fixtures = Mutex<[String: Fixture]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try #require(request.url)
            let host = try #require(url.host)
            let post = try JSONDecoder().decode(Posted.self, from: body())
            let status = try Self.fixtures.withLock { fixtures in
                var fixture = try #require(fixtures[host])
                let status = try #require(fixture.statuses.first)
                fixture.statuses.removeFirst()
                fixture.posts.append(post)
                fixtures[host] = fixture
                return status
            }
            let data: Data
            if status == 201 {
                let message = ChannelMessage(id: post.id, sequence: 7, timestamp: "2026-10-24T00:00:00Z",
                                             sender: .user, content: .text(post.content), attachments: post.attachments)
                data = try JSONEncoder().encode(Envelope(message: message))
            } else {
                data = Data(#"{"error":"Rejected"}"#.utf8)
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                       headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func body() throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw ChannelAPIError.invalidResponse }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    override func stopLoading() {}
}

/// The draft a test window shows, which changes like the selected channel.
@MainActor @Observable private final class ShownDraft {
    var draft: ComposerDraft
    init(_ draft: ComposerDraft) { self.draft = draft }
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
    private var finishing: CheckedContinuation<Void, any Error>?

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
        if hangs, !isCancelled {
            try await withCheckedThrowingContinuation { finishing = $0 }
        }
        if isCancelled { throw CancellationError() }
        for (text, isFinal) in finalWords { onResult?(text, isFinal) }
    }

    func cancel() {
        isCancelled = true
        finishing?.resume(throwing: CancellationError())
        finishing = nil
    }
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

@MainActor private final class RecordingDictationTarget: DictationTextTarget {
    var isInKeyWindow = false
    private(set) var begins = 0
    private(set) var commits: [String] = []

    func beginDictation() -> Bool {
        begins += 1
        return true
    }

    func showDictation(_ transcript: DictationTranscript) {}
    func endDictation(_ finalized: String) { commits.append(finalized) }
}

@MainActor private final class MicrophoneProbe {
    var isConnected = false
    var deviceChecks = 0
    var accessChecks = 0
}

@MainActor private final class MicrophoneAccessBox {
    var value = DictationMicrophoneAccess.denied
    var grants = false
    var requests = 0
}
