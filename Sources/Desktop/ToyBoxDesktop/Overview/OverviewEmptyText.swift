import SwiftUI
import ToyBoxUI

/// One secondary sentence for a section that has nothing in it yet.
struct OverviewEmptyText: View {
    @Environment(\.channelTextScale) private var textScale
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12 * textScale))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }
}
