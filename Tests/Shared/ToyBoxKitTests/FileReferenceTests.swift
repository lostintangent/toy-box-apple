import Foundation
import Testing
@testable import ToyBoxKit

struct FileReferenceTests {
    @Test func anEscapedRelativeLinkNamesTheSendersOwnArtifact() throws {
        let markdown = MarkdownBlock.parsedInlineMarkdown("[Itinerary](file:Holiday%20itinerary%202026.html)")
        let url = try #require(markdown.runs.compactMap(\.link).first)
        let reference = try #require(FileReference(url))
        #expect(reference.path == "Holiday itinerary 2026.html")
        let itinerary = session("studio", "Holiday itinerary 2026.html")
        #expect(reference.artifact(in: [itinerary], folder: nil, sender: .agent("studio")) == itinerary)
    }

    @Test func aRelativeLinkWithoutAFolderPrefersTheSendersArtifactOverTheNewest() {
        let ada = session("ada", "plan.md", shared: "2026-11-18T10:00:00Z")
        let pixel = session("pixel", "plan.md", shared: "2026-11-18T12:00:00Z")
        let older = session("moss", "plan.md", shared: "2026-11-18T08:00:00Z")
        let artifacts = [older, ada, pixel]
        let plan = FileReference(path: "./plan.md")
        #expect(plan.artifact(in: artifacts, folder: nil, sender: .agent("ada")) == ada)
        #expect(plan.artifact(in: artifacts, folder: nil, sender: .agent("lead")) == pixel)
        #expect(plan.artifact(in: artifacts, folder: nil, sender: .user) == pixel)
        #expect(FileReference(path: "../plan.md").artifact(in: artifacts, folder: nil, sender: .agent("ada")) == nil)
        #expect(FileReference(path: "notes.md").artifact(in: artifacts, folder: nil, sender: .agent("ada")) == nil)
    }

    @Test func aRelativeLinkJoinsTheChannelsFolder() {
        let notes = machine("/work/app/docs/notes.md")
        let artifacts = [notes, session("ada", "docs/notes.md")]
        #expect(FileReference(path: "docs/./drafts/../notes.md")
            .artifact(in: artifacts, folder: "/work/app/", sender: .agent("ada")) == notes)
        #expect(FileReference(path: "notes.md").artifact(in: artifacts, folder: "/work/app", sender: .agent("ada")) == nil)
    }

    @Test func anAbsoluteLinkNamesASessionArtifactInsideItsArtifactsFolderAndOtherwiseAMachineFile() throws {
        let sketch = session("abc", "sub/a b.md")
        let notes = machine("/demo/Interaction notes.md")
        let artifacts = [sketch, notes]
        let url = try #require(URL(string: "file:/Users/x/.toy-box/sessions/abc/artifacts/sub/a%20b.md"))
        let inSession = try #require(FileReference(url))
        #expect(inSession.artifact(in: artifacts, folder: "/work", sender: .user) == sketch)
        #expect(FileReference(path: "/demo/Interaction notes.md").artifact(in: artifacts, folder: nil, sender: .user) == notes)
        #expect(FileReference(path: "/Users/x/.toy-box/sessions/abc/sub/a b.md")
            .artifact(in: artifacts, folder: nil, sender: .user) == nil)
        #expect(FileReference(path: "/demo/Other.md").artifact(in: artifacts, folder: nil, sender: .user) == nil)
    }

    @Test func onlyADecodableFileLinkIsAReference() throws {
        #expect(FileReference(try #require(URL(string: "https://example.com/plan.md"))) == nil)
        #expect(FileReference(try #require(URL(string: "file:"))) == nil)
        #expect(FileReference(try #require(URL(string: "FILE:plan.md")))?.path == "plan.md")
    }

    private func session(_ id: String, _ path: String, shared: String? = nil) -> ChannelArtifact {
        ChannelArtifact(file: .init(kind: "session", sessionId: id, path: path), title: path, sharedAt: shared)
    }

    private func machine(_ path: String) -> ChannelArtifact {
        ChannelArtifact(file: .init(kind: "machine", path: path), title: path)
    }
}
