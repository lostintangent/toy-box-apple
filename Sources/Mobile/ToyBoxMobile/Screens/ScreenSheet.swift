import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// The host's screens over the sidebar. Choosing one watches it full screen, and closing the viewer
/// returns to the list.
struct ScreenSheet: View {
    let api: ChannelAPI
    @Environment(\.dismiss) private var dismiss
    @ViewState private var watching: Screen?

    var body: some View {
        NavigationStack {
            ScreenBrowser(api: api) { watching = $0 }
                .navigationTitle("Screens")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                            .accessibilityLabel("Close Screens")
                    }
                }
        }
        .fullScreenCover(item: $watching) { ScreenViewer(api: api, screenID: $0.id) }
    }
}
