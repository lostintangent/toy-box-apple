import SwiftUI
import ToyBoxUI

/// A compact About property: an 18-point symbol column, 6 points, then a 12-point value.
struct OverviewPropertyRow<Value: View>: View {
    @Environment(\.channelTextScale) private var textScale
    let symbol: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13 * textScale))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            value().font(.system(size: 12 * textScale))
        }
        .frame(minHeight: 22)
    }
}
