import SwiftUI

package struct ChannelTaskAncestryGuide: View {
    private let statusWidth: CGFloat
    private let topClearance: CGFloat
    private let bottomClearance: CGFloat
    @Environment(\.displayScale) private var scale

    package init(statusWidth: CGFloat, topClearance: CGFloat = 4, bottomClearance: CGFloat = 4) {
        self.statusWidth = statusWidth
        self.topClearance = topClearance
        self.bottomClearance = bottomClearance
    }

    package var body: some View {
        let lineWidth: CGFloat = 1
        let leading = ((statusWidth / 2 - lineWidth / 2) * scale).rounded() / scale
        Rectangle()
            .fill(separator, style: FillStyle(antialiased: false))
            .frame(width: lineWidth)
            .padding(.top, topClearance)
            .padding(.bottom, bottomClearance)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, leading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var separator: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }
}
