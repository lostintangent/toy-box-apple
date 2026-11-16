import SwiftUI
import Testing
import ToyBoxClient
import ToyBoxKit
import ToyBoxUI
@testable import ToyBoxDesktop

/// t1238 spike: plain SwiftUI scrolling around the Mac's real rows, one per message.
@MainActor
@Suite(.serialized) struct ScrollSpikeTests {
    @Test func realRows() async throws {
        let viewer = ImageViewer()
        let opener = ArtifactOpener()
        try await runAllSpikeCases(SpikeCases(size: CGSize(width: 720, height: 700)) { spike in
            let channel = TranscriptRowChannel(agents: SpikeFixture.agents, id: spike.store.id,
                                               historyStart: spike.messages.first?.sequence ?? 0, api: spike.store.api)
            return SpikeFixture.split(spike.rows).map { row, spacing in
                SpikeItem(id: row.id, view: AnyView(
                    TranscriptRowContent(row: row, channel: channel, statusReactions: [:], highlightedSequence: nil,
                                         catchUp: nil, store: spike.store, expandedMessageIds: [],
                                         onSetExpanded: { _, _ in })
                        .equatable()
                        .padding(.top, spacing)
                        .padding(.horizontal, 20)
                        .environment(viewer)
                        .environment(opener)))
            }
        })
    }
}
