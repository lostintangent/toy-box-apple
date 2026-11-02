import Foundation
import Testing
@testable import ChannelKit

struct ArtifactTests {
    @Test func contentKindsKeepSVGBeforeTheGeneralImageFallback() {
        #expect(ArtifactContentKind(artifact("notes.MD")) == .markdown)
        #expect(ArtifactContentKind(artifact("page.htm")) == .html)
        #expect(ArtifactContentKind(artifact("drawing.svg")) == .svg)
        #expect(ArtifactContentKind(artifact("photo.png")) == .image)
        #expect(ArtifactContentKind(artifact("report.pdf")) == .file)
    }

    @Test func pagingUsesTheChannelsNewestFirstOrderingWithoutWrapping() {
        let old = artifact("old.md", shared: "2026-10-24T20:00:00Z")
        let latest = artifact("latest.html", shared: "2026-10-24T22:00:00Z")
        let middle = artifact("middle.svg", shared: "2026-10-24T21:00:00Z")
        var pages = ArtifactPageList(artifacts: [old, latest, middle], opening: middle)
        #expect(pages.artifacts.map(\.id) == [latest.id, middle.id, old.id])
        #expect(pages.index == 1)
        let showedLatest = pages.move(by: -1)
        #expect(showedLatest)
        #expect(pages.selected == latest)
        let wrappedToOldest = pages.move(by: -1)
        #expect(!wrappedToOldest)
        let showedOldest = pages.move(by: 2)
        #expect(showedOldest)
        #expect(pages.selected == old)
        #expect(!pages.canShowNext)
        let selectedMissing = pages.select("not-an-artifact")
        #expect(!selectedMissing)
        #expect(pages.selected == old)
        pages.update([latest, middle])
        #expect(pages.selected == nil)
    }

    @Test func aTaskArtifactCanOpenBeforeItAppearsInTheSharedList() {
        let task = artifact("task.md")
        let shared = artifact("shared.svg")
        let pages = ArtifactPageList(artifacts: [shared], opening: task)
        #expect(pages.artifacts == [task, shared])
        #expect(pages.selected == task)
    }

    private func artifact(_ path: String, shared: String? = nil) -> ChannelArtifact {
        ChannelArtifact(file: .init(kind: "machine", path: path), title: path, sharedAt: shared,
                        url: "/api/serve/test/\(path)")
    }
}
