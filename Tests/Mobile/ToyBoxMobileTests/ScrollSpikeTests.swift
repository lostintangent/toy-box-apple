import SwiftUI
import Testing
import ToyBoxClient
import ToyBoxKit
import ToyBoxUI
@testable import ToyBoxMobile

/// t1238 spike: plain SwiftUI scrolling around the phone's real items, one per message.
@MainActor
@Suite(.serialized) struct ScrollSpikeTests {
    @Test func realRows() async throws {
        try await runAllSpikeCases(SpikeCases(size: CGSize(width: 393, height: 760)) { spike in
            let channel = TranscriptRowChannel(id: spike.store.id, agents: SpikeFixture.agents, api: spike.store.api)
            return transcriptItems(spike.rows).map { item in
                SpikeItem(id: item.id, view: AnyView(
                    TranscriptItemView(item: item, channel: channel, statusReactions: [:], isHighlighted: false)
                        .padding(.top, item.spacing)
                        .padding(.horizontal, 16)))
            }
        })
    }
}
