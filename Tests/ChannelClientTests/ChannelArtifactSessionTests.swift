import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

@MainActor
struct ChannelArtifactSessionTests {
    @Test(arguments: [false, true])
    func switchingScopeDiscardsTheVisitAndCancelsItsPendingLoad(changingServer: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Shared document".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let downloads = ArtifactDownloads(file: file)
        let session = ChannelArtifactSession(decodeImage: { _, _, _ in
            throw ChannelAttachmentError.invalidImage
        }, download: { artifact, _ in await downloads.file(for: artifact) })
        let api = try ChannelAPI(baseURL: URL(string: "http://localhost:3210")!)
        let original = artifact("original.md")
        let next = artifact("next.md")
        session.configure(api: api, channelID: "first", artifacts: [original])
        await downloads.hold(original)
        session.open(original)
        try await wait { await downloads.hasRequested(original) }
        let obsolete = try #require(session.loadTask)
        let replacement = changingServer ? try ChannelAPI(baseURL: URL(string: "https://other.example")!) : api
        session.configure(api: replacement, channelID: changingServer ? "first" : "second", artifacts: [next])
        #expect(!session.isPresented)
        #expect(!session.isLoading)
        session.open(next)
        try await wait { !session.isLoading }
        await downloads.release(original)
        await obsolete.value
        #expect(session.artifact?.id == next.id)
        #expect(session.content?.artifact.id == next.id)
        #expect(session.content?.text == "Shared document")
        #expect(session.content?.server == replacement.baseURL)
        #expect(session.loadError == nil)
        #expect(session.actionError == nil)
        session.close()
        #expect(session.content == nil)
        #expect(session.pages == nil)
    }

    @Test func removingAnArtifactDuringLoadingRetainsItsIdentityWithoutPublishingTheResponse() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Removed".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let downloads = ArtifactDownloads(file: file)
        let session = ChannelArtifactSession(decodeImage: { _, _, _ in
            throw ChannelAttachmentError.invalidImage
        }, download: { artifact, _ in await downloads.file(for: artifact) })
        let selected = artifact("removed.md")
        let neighbor = artifact("neighbor.md")
        session.configure(api: try ChannelAPI(baseURL: URL(string: "http://localhost:3210")!),
                          channelID: "test", artifacts: [selected, neighbor])
        await downloads.hold(selected)
        session.open(selected)
        try await wait { await downloads.hasRequested(selected) }
        let obsolete = try #require(session.loadTask)
        session.update([neighbor])
        await downloads.release(selected)
        await obsolete.value
        #expect(session.artifact?.id == selected.id)
        #expect(session.isUnavailable)
        #expect(session.content == nil)
        #expect(!session.isLoading)
        session.select(neighbor.id)
        try await wait { !session.isLoading }
        #expect(session.content?.artifact.id == neighbor.id)
        #expect(!session.isUnavailable)
        session.close()
    }

    private func artifact(_ path: String) -> ChannelArtifact {
        ChannelArtifact(file: .init(kind: "machine", path: path), title: path, url: "/api/serve/test/\(path)")
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition())
    }
}

private actor ArtifactDownloads {
    let prepared: URL
    private var held: Set<String> = []
    private var requests: Set<String> = []
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]

    init(file: URL) { prepared = file }
    func hold(_ artifact: ChannelArtifact) { held.insert(artifact.id) }
    func hasRequested(_ artifact: ChannelArtifact) -> Bool { requests.contains(artifact.id) }
    func release(_ artifact: ChannelArtifact) {
        held.remove(artifact.id)
        pending.removeValue(forKey: artifact.id)?.resume()
    }
    func file(for artifact: ChannelArtifact) async -> URL {
        requests.insert(artifact.id)
        if held.contains(artifact.id) { await withCheckedContinuation { pending[artifact.id] = $0 } }
        return prepared
    }
}
