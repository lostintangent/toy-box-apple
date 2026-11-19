import Foundation
import Testing
@testable import ToyBoxKit

struct FileReferenceTests {
    @Test func anEscapedRelativeLinkWithoutAFolderNamesTheNewestArtifactAtThatPath() throws {
        let markdown = MarkdownBlock.parsedInlineMarkdown("[Itinerary](file:Holiday%20itinerary%202026.html)")
        let url = try #require(markdown.runs.compactMap(\.link).first)
        let reference = try #require(FileReference(url))
        #expect(reference.path == "Holiday itinerary 2026.html")
        let older = session("studio", "Holiday itinerary 2026.html", shared: "2026-11-18T10:00:00Z")
        let newest = session("pixel", "Holiday itinerary 2026.html", shared: "2026-11-18T12:00:00Z")
        let artifacts = [older, newest, session("moss", "plan.md", shared: "2026-11-18T14:00:00Z")]
        #expect(reference.artifact(in: artifacts, folder: nil) == newest)
        #expect(FileReference(path: "../drafts/../Holiday itinerary 2026.html")
            .artifact(in: artifacts, folder: nil) == newest)
        #expect(FileReference(path: "notes.md").artifact(in: artifacts, folder: nil) == nil)
    }

    @Test func aRelativeLinkJoinsTheChannelsFolder() {
        let notes = machine("/work/app/docs/notes.md")
        let artifacts = [notes, session("ada", "docs/notes.md")]
        #expect(FileReference(path: "docs/./drafts/../notes.md")
            .artifact(in: artifacts, folder: "/work/app/") == notes)
        #expect(FileReference(path: "notes.md").artifact(in: artifacts, folder: "/work/app") == nil)
    }

    @Test func anAbsoluteLinkNamesASessionArtifactInsideItsArtifactsFolderAndOtherwiseAMachineFile() throws {
        let sketch = session("abc", "sub/a b.md")
        let notes = machine("/demo/Interaction notes.md")
        let artifacts = [sketch, notes]
        let url = try #require(URL(string: "file:/Users/x/.toy-box/sessions/abc/artifacts/sub/a%20b.md"))
        let inSession = try #require(FileReference(url))
        #expect(inSession.artifact(in: artifacts, folder: "/work") == sketch)
        #expect(FileReference(path: "/demo/Interaction notes.md").artifact(in: artifacts, folder: nil) == notes)
        #expect(FileReference(path: "/Users/x/.toy-box/sessions/abc/sub/a b.md")
            .artifact(in: artifacts, folder: nil) == nil)
        #expect(FileReference(path: "/Users/x/.toy-box/sessions/abc/artifacts/")
            .artifact(in: artifacts, folder: nil) == nil)
        #expect(FileReference(path: "/demo/Other.md").artifact(in: artifacts, folder: nil) == nil)
    }

    @Test func aFileLinkIsItsDecodedPathAsABrowserReadsIt() throws {
        #expect(FileReference(try #require(URL(string: "https://example.com/plan.md"))) == nil)
        #expect(FileReference(try #require(URL(string: "file:"))) == nil)
        #expect(FileReference(try #require(URL(string: "FILE:plan.md")))?.path == "plan.md")
        #expect(FileReference(try #require(URL(string: "file:plan.md?v=2#intro")))?.path == "plan.md")
        #expect(FileReference(try #require(URL(string: "file://localhost/demo/a%20b.md")))?.path == "/demo/a b.md")
    }

    private func session(_ id: String, _ path: String, shared: String? = nil) -> ChannelArtifact {
        ChannelArtifact(file: .init(kind: "session", sessionId: id, path: path), title: path, sharedAt: shared)
    }

    private func machine(_ path: String) -> ChannelArtifact {
        ChannelArtifact(file: .init(kind: "machine", path: path), title: path)
    }
}
