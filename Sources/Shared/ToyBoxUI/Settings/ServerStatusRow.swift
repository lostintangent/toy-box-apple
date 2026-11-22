import ToyBoxClient
import SwiftUI

/// A server's Status: its dot and the word for it, as its row and the sidebar footer show them. It
/// never says why. See Settings in docs/spec.md.
public struct ServerStatusRow: View {
    let catalog: ChannelCatalogStore

    public init(_ catalog: ChannelCatalogStore) { self.catalog = catalog }

    public var body: some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        LabeledContent("Status") {
            HStack(spacing: 6) {
                Circle().fill(footer.dot).frame(width: Self.dot, height: Self.dot)
                Text(footer.word)
            }
        }
    }

    /// Each app's server list dot.
    #if os(macOS)
    private static let dot: CGFloat = 7
    #else
    private static let dot: CGFloat = 8
    #endif
}
