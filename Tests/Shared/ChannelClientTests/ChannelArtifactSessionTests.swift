import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

@MainActor @Suite(.timeLimit(.minutes(1)))
struct ChannelArtifactSessionTests {
    @Test(arguments: [ArtifactVisitInvalidation.channel, .server, .removal])
    func anObsoleteLoadCannotEndOrReplaceItsSuccessorsPendingVisit(change: ArtifactVisitInvalidation) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Shared document".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let downloads = ArtifactDownloads(file: file)
        let session = ChannelArtifactSession(decodeImage: { _, _, _ in
            throw ChannelAttachmentError.invalidImage
        }, download: { artifact, _ in await downloads.file(for: artifact) })
        defer { session.close() }
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        let original = artifact("original.md"), next = artifact("next.md")
        session.configure(api: api, channelID: "first", artifacts: [original, next])
        await downloads.hold(original)
        await downloads.hold(next)
        var requests = downloads.requestEvents.makeAsyncIterator()
        session.open(original)
        let obsolete = try #require(session.loadTask)
        var current: Task<Void, Never>?
        do {
            #expect(await requests.next() == original.id)
            #expect(session.isLoading)
            let replacement = change == .server ? try ChannelAPI(serverURL: "https://other.example") : api
            if change == .removal {
                session.update([next])
                #expect(session.artifact?.id == original.id)
                #expect(session.isUnavailable)
                #expect(!session.isLoading)
                #expect(session.content == nil)
                #expect(session.select(next.id))
            } else {
                #expect(session.configure(api: replacement, channelID: change == .channel ? "second" : "first",
                                          artifacts: [next]))
                #expect(!session.isPresented)
                #expect(!session.isLoading)
                #expect(session.pages == nil)
                session.open(next)
            }
            #expect(obsolete.isCancelled)
            let successor = try #require(session.loadTask)
            current = successor
            #expect(await requests.next() == next.id)
            #expect(session.artifact?.id == next.id)
            #expect(session.content == nil)
            #expect(session.isLoading)

            await downloads.release(original)
            await obsolete.value
            #expect(session.artifact?.id == next.id)
            #expect(!session.isUnavailable)
            #expect(session.content == nil)
            #expect(session.isLoading)
            #expect(session.loadError == nil)
            #expect(session.actionError == nil)

            await downloads.release(next)
            await successor.value
            #expect(!session.isLoading)
            #expect(session.content?.artifact.id == next.id)
            #expect(session.content?.text == "Shared document")
            #expect(session.content?.server == replacement.baseURL)
            #expect(session.loadError == nil)
            #expect(session.actionError == nil)
            session.close()
            #expect(session.content == nil)
            #expect(session.pages == nil)
        } catch {
            session.close()
            await downloads.release(original)
            await downloads.release(next)
            await obsolete.value
            await current?.value
            throw error
        }
    }

    /// The removed artifact stays presented with its load's token, so only cancellation keeps its late
    /// response out. The successor cases above change the token before the response arrives.
    @Test func removingAnArtifactDuringLoadingRetainsItsIdentityWithoutPublishingTheResponse() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Removed".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let downloads = ArtifactDownloads(file: file)
        let session = ChannelArtifactSession(decodeImage: { _, _, _ in
            throw ChannelAttachmentError.invalidImage
        }, download: { artifact, _ in await downloads.file(for: artifact) })
        defer { session.close() }
        let selected = artifact("removed.md"), neighbor = artifact("neighbor.md")
        session.configure(api: try ChannelAPI(serverURL: "http://localhost:3210"),
                          channelID: "test", artifacts: [selected, neighbor])
        await downloads.hold(selected)
        var requests = downloads.requestEvents.makeAsyncIterator()
        session.open(selected)
        let obsolete = try #require(session.loadTask)
        #expect(await requests.next() == selected.id)
        session.update([neighbor])
        #expect(obsolete.isCancelled)
        await downloads.release(selected)
        await obsolete.value
        #expect(session.artifact?.id == selected.id)
        #expect(session.isUnavailable)
        #expect(session.content == nil)
        #expect(!session.isLoading)
        #expect(session.loadError == nil)

        #expect(session.select(neighbor.id))
        await session.loadTask?.value
        #expect(session.content?.artifact.id == neighbor.id)
        #expect(!session.isUnavailable)
        #expect(!session.isLoading)
    }

    private func artifact(_ path: String) -> ChannelArtifact {
        ChannelArtifact(file: .init(kind: "machine", path: path), title: path, url: "/api/serve/test/\(path)")
    }
}

enum ArtifactVisitInvalidation: Sendable { case channel, server, removal }

private actor ArtifactDownloads {
    let prepared: URL
    nonisolated let requestEvents: AsyncStream<String>
    private let reportRequest: AsyncStream<String>.Continuation
    private var held: Set<String> = []
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]

    init(file: URL) {
        prepared = file
        let events = AsyncStream<String>.makeStream()
        requestEvents = events.stream
        reportRequest = events.continuation
    }
    deinit { reportRequest.finish() }
    func hold(_ artifact: ChannelArtifact) { held.insert(artifact.id) }
    func release(_ artifact: ChannelArtifact) {
        held.remove(artifact.id)
        pending.removeValue(forKey: artifact.id)?.resume()
    }
    func file(for artifact: ChannelArtifact) async -> URL {
        reportRequest.yield(artifact.id)
        if held.contains(artifact.id) { await withCheckedContinuation { pending[artifact.id] = $0 } }
        return prepared
    }
}
