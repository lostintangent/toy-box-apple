import SwiftUI

package struct ChannelTaskStatusSymbol: View {
    package let status: String
    private let secondary: Color
    @Environment(\.colorScheme) private var scheme

    package init(status: String, secondary: Color = .secondary) {
        self.status = status
        self.secondary = secondary
    }

    package var body: some View {
        icon.accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.monochrome)
                .fontWeight(.semibold)
                .foregroundStyle(ChannelTaskColors.changes(in: scheme).added)
        case "blocked":
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette)
                .fontWeight(.semibold)
                .foregroundStyle(.white, .red)
        case "in_progress":
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(secondary)
        default:
            Image(systemName: "circle").foregroundStyle(secondary)
        }
    }
}
