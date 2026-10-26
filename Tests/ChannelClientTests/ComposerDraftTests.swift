import ChannelClient
import ChannelKit
import Foundation
import Testing
import UniformTypeIdentifiers

@MainActor @Suite(.timeLimit(.minutes(1)))
struct ComposerDraftTests {
    @Test func textAndOriginalSendIDSurviveRestoration() async throws {
        try await withDraft { draft, url in
            #expect(!draft.hasContent)
            draft.text = "@lead First draft"
            draft.associateSend(id: "original-send-id")
            let restored = makeDraft(fileURL: url)
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
            let restored = makeDraft(fileURL: url)
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
            let restored = makeDraft(fileURL: url)
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
            let restored = makeDraft(fileURL: url)
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
            let restored = makeDraft(fileURL: url)
            #expect(restored.images.count == attachments.count)
            #expect(restored.hasUnreadableImage)
            #expect(restored.error?.contains("attach") == true)
            for image in draft.images where !isReadableImage(image.data) { draft.removeImage(id: image.id) }
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
        let quickSend = ComposerDraft.storageKey(serverURL: normalized, channelID: "channel", scope: .quickSend)
        let reply = ComposerDraft.storageKey(serverURL: normalized, channelID: "channel", scope: .inboxReply(sequence: 8))
        #expect(Set([key, quickSend, reply]).count == 3)
        #expect(reply != ComposerDraft.storageKey(serverURL: normalized, channelID: "channel",
                                                scope: .inboxReply(sequence: 9)))
        #expect(quickSend == ComposerDraft.storageKey(serverURL: upper, channelID: "channel", scope: .quickSend))
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

    @Test func retryingASaveRecoversWithoutChangingTheDraftOrSendID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-draft-\(UUID())")
        try Data("Not a directory".utf8).write(to: directory)
        defer { remove(directory) }
        let url = directory.appendingPathComponent("draft.json")
        let draft = makeDraft(fileURL: url)
        draft.text = "Keep this text"
        draft.associateSend(id: "original")
        let revision = draft.revision
        #expect(!draft.isSavedLocally)
        try FileManager.default.removeItem(at: directory)
        draft.retrySave()
        #expect(draft.isSavedLocally)
        #expect(draft.error == nil)
        #expect(draft.revision == revision)
        let restored = makeDraft(fileURL: url)
        #expect(restored.text == "Keep this text")
        #expect(restored.sendAttemptID == "original")
    }

    private func makeDraft(fileURL: URL? = nil) -> ComposerDraft {
        ComposerDraft(fileURL: fileURL, imageIsReadable: isReadableImage)
    }

    private func isReadableImage(_ data: Data) -> Bool { data == Self.png }

    private func sampleImage() throws -> ComposerImage {
        .init(name: "Sample.png", mimeType: "image/png", data: try #require(Self.png))
    }

    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")

    private func withDraft(_ body: (ComposerDraft, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-composer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { remove(directory) }
        let url = directory.appendingPathComponent("draft.json")
        try await body(makeDraft(fileURL: url), url)
    }

    private func finishLoading(_ draft: ComposerDraft) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while draft.isLoadingImages {
            try #require(ContinuousClock.now < deadline, "The images never finished loading.")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Composer test cleanup failed: \(error.localizedDescription)") }
    }
}
