import ChannelKit
import CoreGraphics
import Foundation
import Observation
import Synchronization
import Testing
@testable import ChannelClient

@MainActor @Suite(.timeLimit(.minutes(1)))
struct ComposerThumbnailTests {
    @Test func theStoreAppliesEventsWhileAThumbnailDecodeIsHeld() async throws {
        let image = try fixtureImage()
        let bitmap = try fixtureBitmap()
        let started = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish() }
        let release = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        defer { release.continuation.finish() }
        let observed = Mutex((calls: 0, onMainThread: false, bound: 0))
        let draft = ComposerDraft(imageIsReadable: { _ in true })
        draft.append(image)
        draft.thumbnailDecoder = { _, bound in
            observed.withLock {
                $0.calls += 1
                $0.onMainThread = Thread.isMainThread
                $0.bound = bound
            }
            started.continuation.yield(())
            var releases = release.stream.makeAsyncIterator()
            _ = await releases.next()
            return bitmap
        }
        #expect(draft.thumbnail(for: image) == nil)
        #expect(draft.thumbnail(for: image) == nil)
        #expect(observed.withLock { $0.calls } == 0)

        let mock = MockTransport { _, count in
            try .stream([.init(type: "snapshot", state: testState(
                revision: count, messages: [testMessage(count)]
            ))])
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 0.01), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually(observing: mock) {
            store.state?.revision == 1 && store.phase.isLive && mock.pendingResponseCount == 1
        }

        let loading = Task { await draft.loadThumbnail(for: image) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let anotherTile = Task { await draft.loadThumbnail(for: image) }
        #expect(!observed.withLock { $0.onMainThread })
        #expect(draft.thumbnail(for: image) == nil)
        #expect(mock.finishPendingResponses() == 1)
        try await eventually { store.state?.revision == 2 && store.phase.isLive }
        #expect(store.messages.map(\.sequence) == [2])
        #expect(draft.thumbnail(for: image) == nil)
        #expect(draft.images == [image])
        #expect(observed.withLock { $0.bound } == 224)

        loading.cancel()
        release.continuation.yield()
        #expect(await loading.value == nil)
        #expect(await anotherTile.value === bitmap)
        #expect(draft.thumbnail(for: image) === bitmap)
        #expect(await draft.loadThumbnail(for: image) === bitmap)
        #expect(observed.withLock { $0.calls } == 1)
    }

    @Test func aRemovedImagesLateDecodeCannotPopulateTheCacheForItsReplacement() async throws {
        let image = try fixtureImage()
        let oldBitmap = try fixtureBitmap()
        let nextBitmap = try fixtureBitmap()
        let started = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish() }
        let release = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        defer { release.continuation.finish() }
        let calls = Mutex(0)
        let draft = ComposerDraft(imageIsReadable: { _ in true })
        draft.append(image)
        draft.thumbnailDecoder = { _, _ in
            let call = calls.withLock { $0 += 1; return $0 }
            guard call == 1 else { return nextBitmap }
            started.continuation.yield(())
            var releases = release.stream.makeAsyncIterator()
            _ = await releases.next()
            return oldBitmap
        }
        let loading = Task { await draft.loadThumbnail(for: image) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        draft.removeImage(id: image.id)
        release.continuation.yield()
        #expect(await loading.value == nil)
        #expect(draft.thumbnail(for: image) == nil)

        draft.append(image)
        #expect(await draft.loadThumbnail(for: image) === nextBitmap)
        #expect(draft.thumbnail(for: image) === nextBitmap)
        #expect(calls.withLock { $0 } == 2)
        #expect(draft.images == [image])
    }

    @Test func aRetainedThumbnailCannotHideALaterPreparationFailure() async throws {
        let image = ComposerImage(name: "Unreadable.heic", mimeType: "image/heic", data: Data("Unreadable".utf8))
        let bitmap = try fixtureBitmap()
        let draft = ComposerDraft(imageIsReadable: { _ in true })
        draft.thumbnailDecoder = { _, _ in bitmap }
        draft.restore(content: "Keep this caption", attachments: [image.attachment], sendAttemptID: "previous-send")
        let restored = try #require(draft.images.first)
        #expect(!draft.isLoadingImages)
        let retained = try #require(await draft.loadThumbnail(for: restored))
        #expect(retained === bitmap)
        let lookupChanged = Mutex(false)
        withObservationTracking {
            #expect(draft.thumbnail(for: restored, retaining: retained) === bitmap)
        } onChange: {
            lookupChanged.withLock { $0 = true }
        }

        draft.text = "Edited caption"
        #expect(draft.isLoadingImages)
        try await eventually { !draft.isLoadingImages }
        #expect(draft.images == [restored])
        #expect(draft.sendAttemptID == nil)
        #expect(draft.hasUnreadableImage)
        #expect(draft.error?.contains(image.name) == true)
        #expect(lookupChanged.withLock { $0 })
        #expect(draft.thumbnail(for: restored, retaining: retained) == nil)
        #expect(await draft.loadThumbnail(for: restored) == nil)
    }

    private func fixtureImage() throws -> ComposerImage {
        let data = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        return ComposerImage(name: "Fixture.png", mimeType: "image/png", data: data)
    }

    private func fixtureBitmap() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }
}
