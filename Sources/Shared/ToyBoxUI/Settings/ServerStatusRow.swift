import ToyBoxClient
import SwiftUI

/// A server's Status: its dot, as its row shows it, with Connected, Connecting… or Can't connect.
/// The Mac says why after it, and the phone under it. See Settings in docs/spec.md.
public struct ServerStatusRow: View {
    let catalog: ChannelCatalogStore

    public init(_ catalog: ChannelCatalogStore) { self.catalog = catalog }

    public var body: some View {
        LabeledContent("Status") {
            HStack(spacing: 6) {
                Circle().fill(SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded).dot)
                    .frame(width: Self.dot, height: Self.dot)
                Text(words).textSelection(.enabled)
            }
        }
    }

    private var words: String {
        switch catalog.phase {
        case .connecting: "Connecting…"
        case .connected: "Connected"
        #if os(macOS)
        case .failed(let error): "Can't connect. \(error.localizedDescription)"
        #else
        case .failed: "Can't connect"
        #endif
        }
    }

    /// Each app's server list dot.
    #if os(macOS)
    private static let dot: CGFloat = 7
    #else
    private static let dot: CGFloat = 8
    #endif
}
