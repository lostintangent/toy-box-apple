@testable import ToyBoxClient
import ToyBoxKit
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@MainActor @Suite(.timeLimit(.minutes(1)))
struct ComposerDraftTests {
    @Test func textSurvivesRestoration() async throws {
        try await withDraft { draft, url in
            #expect(!draft.hasContent)
            draft.text = "@lead First draft"
            try await saved(draft)
            let restored = makeDraft(fileURL: url)
            #expect(draft.error == nil)
            #expect(restored.text == draft.text)
        }
    }

    @Test func sendabilityKeepsTheExactLengthBoundaryAndBlocksEachDraftCondition() {
        let draft = ComposerDraft(imageIsReadable: { _ in true })
        #expect(!draft.isSendable())
        #expect(draft.isSendable(hasAdditionalContent: true))
        #expect(!draft.isSendable(hasAdditionalContent: true, isLoadingAdditionalImages: true))
        draft.text = String(repeating: "a", count: ChannelMessage.maxLength)
        #expect(draft.isSendable())
        draft.text += "a"
        #expect(draft.isOverLimit)
        #expect(!draft.isSendable(hasAdditionalContent: true))
    }

    @Test func keptWordsLandOneBlankLineAfterTheDraftWhateverWhitespaceItEndsIn() {
        #expect(ComposerDraft.joined("", "Words") == "Words")
        #expect(ComposerDraft.joined(" \n", "Words") == "Words")
        #expect(ComposerDraft.joined("  Draft\n\n\n", "Words") == "  Draft\n\nWords")
        #expect(ComposerDraft.joined("Draft \n", " \n") == "Draft \n")
    }

    @Test func anOldCompletionCannotEraseANewerDraft() async throws {
        try await withDraft { draft, _ in
            draft.text = "Original"
            let originalRevision = draft.revision
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
            try await saved(draft)
            let restored = makeDraft(fileURL: url)
            #expect(restored.images.first?.data == image.data)
            let metadata = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
            #expect(!metadata.contains(image.data.base64EncodedString()))
            draft.removeImage(id: image.id)
            #expect(draft.images.isEmpty)
            try await saved(draft)
            let imageURL = url.deletingPathExtension().appendingPathComponent(image.id.uuidString)
            #expect(!FileManager.default.fileExists(atPath: imageURL.path))
        }
    }

    @Test func missingRestoredImagesRequireReattachment() async throws {
        try await withDraft { draft, url in
            let image = try sampleImage()
            draft.append(image)
            try await saved(draft)
            let imageURL = url.deletingPathExtension().appendingPathComponent(image.id.uuidString)
            try FileManager.default.removeItem(at: imageURL)
            let restored = makeDraft(fileURL: url)
            #expect(restored.images.count == 1)
            #expect(restored.hasUnreadableImage)
            #expect(restored.error?.contains("attach") == true)
        }
    }

    @Test func anAttachmentOnlyDraftClears() async throws {
        try await withDraft { draft, url in
            draft.append(try sampleImage())
            draft.clear(ifUnchanged: draft.revision)
            #expect(!draft.hasContent)
            #expect(draft.images.isEmpty)
            try await saved(draft)
            let restored = makeDraft(fileURL: url)
            #expect(!restored.hasContent)
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
            draft.restore(content: "Keep every attachment", attachments: attachments)
            #expect(draft.images.count == attachments.count)
            #expect(draft.hasUnreadableImage)
            #expect(draft.images.last?.data == readable.data)
            #expect(draft.error?.contains("before sending") == true)
            try await saved(draft)
            let restored = makeDraft(fileURL: url)
            #expect(restored.images.count == attachments.count)
            #expect(restored.hasUnreadableImage)
            #expect(restored.error?.contains("attach") == true)
            for image in draft.images where !isReadableImage(image.data) { draft.removeImage(id: image.id) }
            #expect(draft.images.count == 1)
            #expect(!draft.hasUnreadableImage)
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

    @Test func retryingASaveRecoversWithoutChangingTheDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-draft-\(UUID())")
        try Data("Not a directory".utf8).write(to: directory)
        defer {
            ComposerDraft.finishSaving()
            remove(directory)
        }
        let url = directory.appendingPathComponent("draft.json")
        let draft = makeDraft(fileURL: url)
        draft.text = "Keep this text"
        let revision = draft.revision
        try await eventually { draft.error != nil }
        #expect(draft.error?.contains("could not be saved") == true)
        #expect(!draft.isSavedLocally)
        try FileManager.default.removeItem(at: directory)
        draft.retrySave()
        #expect(!draft.isSavedLocally, "A draft counts as saved only once it's on disk.")
        try await saved(draft)
        #expect(draft.isSavedLocally)
        #expect(draft.error == nil)
        #expect(draft.revision == revision)
        let restored = makeDraft(fileURL: url)
        #expect(restored.text == "Keep this text")
    }

    @Test func aBurstOfKeysEndsWithTheNewestDraftOnDiskWhenTheAppLeaves() async throws {
        try await withDraft { draft, url in
            let typed = "Typing while the disk is busy"
            for character in typed { draft.text.append(character) }
            #expect(draft.isSaving)
            ComposerDraft.finishSaving()
            #expect(makeDraft(fileURL: url).text == typed)
            try await saved(draft)
            #expect(draft.isSavedLocally)
            #expect(draft.error == nil)
        }
    }

    @Test func aClearAfterSendingLandsAfterEveryEarlierWrite() async throws {
        try await withDraft { draft, url in
            draft.append(try sampleImage())
            draft.text = "Sent"
            draft.text += " just now"
            draft.clear(ifUnchanged: draft.revision)
            try await saved(draft)
            #expect(!makeDraft(fileURL: url).hasContent)
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingPathExtension().path).isEmpty)
        }
    }

    @Test func cameraPhotosBecomeOrientedJPEGAndThumbnailsStayCachedWhileTyping() async throws {
        let image = try await Task.detached {
            try Self.generatedImage(width: 1_200, height: 400, type: .heic, orientation: 6)
        }.value
        let draft = imageIODraft()
        draft.text = "Keep this photo caption"
        let earlierRevision = draft.revision
        draft.append(image)
        draft.clear(ifUnchanged: earlierRevision)
        #expect(draft.isLoadingImages)
        try await finishLoading(draft)
        #expect(draft.text == "Keep this photo caption")
        let prepared = try #require(draft.images.first)
        #expect(prepared.id == image.id)
        #expect(prepared.name == "Generated.jpg")
        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.data.count <= 5_000_000)
        let source = try #require(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 400)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1_200)
        let thumbnail = try #require(await draft.loadThumbnail(for: prepared))
        #expect(max(thumbnail.width, thumbnail.height) <= 224)
        draft.text = "Typing must not decode this photo again"
        #expect(draft.thumbnail(for: prepared) === thumbnail)
        let unchanged = try sampleImage()
        draft.append(unchanged)
        #expect(draft.images.last?.data == unchanged.data)
        #expect(draft.error == nil)
    }

    /// Noise at full quality passes 5 MB with few pixels, which keeps this inside its time limit while a CI
    /// simulator is still busy with its first boot.
    @Test func oversizedImagesRespectBothProviderLimits() async throws {
        let images = try await Task.detached {
            [
                try Self.generatedImage(width: 9_001, height: 2, type: .png),
                try Self.generatedImage(width: 1_200, height: 1_200, type: .jpeg, noisy: true, quality: 1),
            ]
        }.value
        try #require(images[1].data.count > 5_000_000)
        for image in images {
            let draft = imageIODraft()
            draft.append(image)
            try await finishLoading(draft)
            let prepared = try #require(draft.images.first)
            #expect(prepared.data.count <= 5_000_000)
            #expect(prepared.mimeType == "image/jpeg")
            let source = try #require(CGImageSourceCreateWithData(prepared.data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
            let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
            #expect(max(width, height) <= 8_000)
            #expect(draft.error == nil)
        }
    }

    @Test func aHeavyImageShrinksUntilItFitsTheBytesItsGiven() async throws {
        let image = try await Task.detached {
            try Self.generatedImage(width: 512, height: 512, type: .jpeg, noisy: true, quality: 1)
        }.value
        let prepared = try await Task.detached { try image.preparedForSending(maximumBytes: 150_000) }.value
        #expect(prepared.data.count <= 150_000)
        #expect(prepared.mimeType == "image/jpeg")
        let source = try #require(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        #expect(width < 512)
    }

    @Test func nativeRasterizationRunsOffTheMainActorWithTheProviderBound() async throws {
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bitmap = try #require(context.makeImage())
        let observed = Mutex<(mainThread: Bool?, bound: Int?)>((nil, nil))
        let draft = ComposerDraft(imageIsReadable: { _ in true }, rasterizeImage: { _, bound in
            observed.withLock { $0 = (Thread.isMainThread, bound) }
            return bitmap
        })
        draft.append(.init(name: "Native.svg", mimeType: "image/svg+xml", data: Data("<svg/>".utf8)))
        try await finishLoading(draft)
        let result = observed.withLock { $0 }
        #expect(result.mainThread == false)
        #expect(result.bound == 8_000)
        #expect(draft.images.first?.mimeType == "image/jpeg")
        #expect(draft.error == nil)
    }

    @Test func legacyUnsentDraftsNormalizeAndRewriteTheirSavedImageBytes() async throws {
        let images = try await Task.detached {
            [
                try Self.generatedImage(width: 64, height: 32, type: .heic),
                try Self.generatedImage(width: 9_001, height: 2, type: .png),
            ]
        }.value
        for image in images {
            try await withDraft { draft, url in
                // This draft reads only the sample PNG, so it saves these images as they are.
                draft.restore(content: "Legacy caption", attachments: [image.attachment])
                let original = try #require(draft.images.first)
                let legacyThumbnail = try #require(await draft.loadThumbnail(for: original))
                try await saved(draft)
                let restored = imageIODraft(fileURL: url)
                #expect(restored.isLoadingImages)
                #expect(restored.thumbnail(for: original) === legacyThumbnail)
                restored.text += " edited during conversion"
                try await finishLoading(restored)
                let prepared = try #require(restored.images.first)
                #expect(prepared.id == original.id)
                #expect(prepared.mimeType == "image/jpeg")
                #expect(prepared.data.count <= 5_000_000)
                let source = try #require(CGImageSourceCreateWithData(prepared.data as CFData, nil))
                let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                #expect(try #require(properties[kCGImagePropertyPixelWidth] as? Int) <= 8_000)
                #expect(try #require(properties[kCGImagePropertyPixelHeight] as? Int) <= 8_000)
                #expect(restored.text == "Legacy caption edited during conversion")
                #expect(restored.error == nil)
                #expect(await restored.loadThumbnail(for: prepared) !== legacyThumbnail)
                try await saved(restored)
                let bytes = try Data(contentsOf: url.deletingPathExtension().appendingPathComponent(prepared.id.uuidString))
                #expect(bytes == prepared.data)
                let reopened = imageIODraft(fileURL: url)
                #expect(reopened.images == restored.images)
                #expect(!reopened.isLoadingImages)
            }
        }
    }

    @Test func failedRestoredImagePreparationRetainsTheOriginalAndBlocksSending() async throws {
        let image = ComposerImage(name: "Unreadable.heic", mimeType: "image/heic", data: Data("Unreadable".utf8))
        let draft = ComposerDraft(imageIsReadable: { _ in true })
        draft.restore(content: "Keep this caption", attachments: [image.attachment])
        #expect(draft.isLoadingImages)
        try await finishLoading(draft)
        #expect(draft.text == "Keep this caption")
        #expect(draft.images.first?.data == image.data)
        #expect(draft.hasUnreadableImage)
        #expect(draft.error?.contains(image.name) == true)
        let restored = try #require(draft.images.first)
        #expect(draft.thumbnail(for: restored) == nil)
    }

    @Test func reattachmentReplacesOnlyItsSlotAndPersistsNormalizedBytes() async throws {
        let replacement = try await Task.detached {
            try Self.generatedImage(width: 64, height: 32, type: .heic)
        }.value
        try await withDraft { _, url in
            let draft = imageIODraft(fileURL: url)
            let readable = try sampleImage()
            draft.restore(content: "Keep this caption", attachments: [
                readable.attachment, .init(name: "Missing.png", mimeType: "image/png"), readable.attachment,
            ])
            let original = draft.images
            let slot = original[1]
            #expect(draft.thumbnail(for: slot) == nil)
            let replacementURL = url.deletingLastPathComponent().appendingPathComponent(replacement.name)
            try replacement.data.write(to: replacementURL)
            #expect(await draft.reattachImage(id: slot.id, from: replacementURL))
            #expect(draft.images.count == original.count)
            #expect(draft.images[0] == original[0])
            #expect(draft.images[2] == original[2])
            let prepared = draft.images[1]
            #expect(prepared.id == slot.id)
            #expect(prepared.name == "Generated.jpg")
            #expect(prepared.mimeType == "image/jpeg")
            #expect(prepared.data.count <= 5_000_000)
            #expect(await draft.loadThumbnail(for: prepared) != nil)
            #expect(draft.text == "Keep this caption")
            #expect(!draft.hasUnreadableImage)
            #expect(!draft.isLoadingImages)
            #expect(draft.error == nil)
            try await saved(draft)
            let bytes = try Data(contentsOf: url.deletingPathExtension().appendingPathComponent(slot.id.uuidString))
            #expect(bytes == prepared.data)
            let reopened = imageIODraft(fileURL: url)
            #expect(reopened.images == draft.images)
        }
    }

    @Test func failedReattachmentKeepsItsSlotWithANamedError() async throws {
        try await withDraft { _, url in
            let draft = imageIODraft()
            draft.restore(content: "Keep this caption", attachments: [
                .init(name: "Missing.png", mimeType: "image/png"),
            ])
            let original = draft.images
            let slot = try #require(original.first)
            for name in ["Corrupt.png", "Unsupported.txt", "Does not exist.png"] {
                let replacement = url.deletingLastPathComponent().appendingPathComponent(name)
                if name != "Does not exist.png" { try Data("Not an image".utf8).write(to: replacement) }
                #expect(await !draft.reattachImage(id: slot.id, from: replacement))
                #expect(draft.images == original)
                #expect(draft.text == "Keep this caption")
                #expect(draft.error?.contains(name) == true)
                #expect(draft.hasUnreadableImage)
                #expect(!draft.isLoadingImages)
            }
        }
    }

    @Test func reattachmentNeverClearsARepeatedDraftPersistenceFailure() async throws {
        try await withDraft { _, url in
            let blocked = url.deletingLastPathComponent().appendingPathComponent("blocked")
            try Data("Not a directory".utf8).write(to: blocked)
            let draft = imageIODraft(fileURL: blocked.appendingPathComponent("draft.json"))
            draft.restore(content: "Keep this caption", attachments: [
                .init(name: "Missing.png", mimeType: "image/png"),
            ])
            try await saved(draft)
            let slot = try #require(draft.images.first)
            let previousError = try #require(draft.error)
            #expect(previousError.contains("could not be saved"))
            let image = try sampleImage()
            let replacement = url.deletingLastPathComponent().appendingPathComponent(image.name)
            try image.data.write(to: replacement)
            #expect(await draft.reattachImage(id: slot.id, from: replacement))
            try await saved(draft)
            #expect(!draft.isSavedLocally)
            #expect(draft.error == previousError)
            #expect(draft.images.first?.data == image.data)
        }
    }

    @Test(arguments: ["cancel", "remove", "replace"])
    func anInFlightReattachmentCannotOutliveItsCancellationOrSlot(change: String) async throws {
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bitmap = try #require(context.makeImage())
        let started = AsyncStream.makeStream(of: Void.self)
        defer { started.continuation.finish() }
        let release = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        defer { release.continuation.finish() }
        try await withDraft { _, url in
            let draft = ComposerDraft(imageIsReadable: { !$0.isEmpty }, rasterizeImage: { _, _ in
                started.continuation.yield()
                var releases = release.stream.makeAsyncIterator()
                _ = await releases.next()
                return bitmap
            })
            draft.restore(content: "Keep this caption", attachments: [
                .init(name: "Missing.svg", mimeType: "image/svg+xml"),
            ])
            let original = try #require(draft.images.first)
            let replacement = url.deletingLastPathComponent().appendingPathComponent("First.svg")
            try Data("<svg/>".utf8).write(to: replacement)
            let first = Task { await draft.reattachImage(id: original.id, from: replacement) }
            var events = started.stream.makeAsyncIterator()
            await events.next()
            #expect(draft.isLoadingImages)
            #expect(draft.images == [original])
            switch change {
            case "cancel":
                first.cancel()
            case "remove":
                draft.removeImage(id: original.id)
            default:
                let second = url.deletingLastPathComponent().appendingPathComponent("Second.png")
                let image = try sampleImage()
                try image.data.write(to: second)
                #expect(await draft.reattachImage(id: original.id, from: second))
                #expect(draft.images.first?.data == image.data)
            }
            release.continuation.yield()
            #expect(await !first.value)
            #expect(!draft.isLoadingImages)
            #expect(draft.text == "Keep this caption")
            switch change {
            case "cancel":
                #expect(draft.images == [original])
                #expect(draft.error?.contains("First.svg") == true)
                #expect(draft.error?.contains("cancelled") == true)
            case "remove":
                #expect(draft.images.isEmpty)
            default:
                #expect(draft.images.count == 1)
                #expect(draft.images.first?.name == "Second.png")
                #expect(draft.images.first?.id == original.id)
                #expect(draft.error == nil)
            }
        }
    }

    private func imageIODraft(fileURL: URL? = nil) -> ComposerDraft {
        ComposerDraft(fileURL: fileURL, imageIsReadable: { data in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
            return CGImageSourceGetCount(source) > 0
        })
    }

    nonisolated static func generatedImage(width: Int, height: Int, type: UTType,
                                          orientation: Int = 1, noisy: Bool = false,
                                          quality: Double = 0.85) throws -> ComposerImage {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let words = bytes.bindMemory(to: UInt32.self)
            var random: UInt32 = 1
            for index in words.indices {
                random = random &* 1_664_525 &+ 1_013_904_223
                words[index] = noisy ? random | 0xFF000000 : 0xFF0000FF
            }
        }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let bitmap = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, [
            kCGImageDestinationLossyCompressionQuality: quality, kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return ComposerImage(name: "Generated.\(type.preferredFilenameExtension ?? "image")",
                             mimeType: try #require(type.preferredMIMEType), data: data as Data)
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
        defer {
            ComposerDraft.finishSaving()
            remove(directory)
        }
        let url = directory.appendingPathComponent("draft.json")
        try await body(makeDraft(fileURL: url), url)
    }

    private func saved(_ draft: ComposerDraft) async throws {
        try await eventually { !draft.isSaving }
    }

    private func finishLoading(_ draft: ComposerDraft) async throws {
        try await eventually { !draft.isLoadingImages }
    }

    private func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Composer test cleanup failed: \(error.localizedDescription)") }
    }
}
