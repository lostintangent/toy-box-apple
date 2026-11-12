import SwiftUI
import ToyBoxUI

/// A failing server's orange or red dot in its header, when the list shows several. Tapping it
/// opens a popover with the status line over the readable failure, then Server Settings, since a
/// wrong address is the one failure a retry can't fix. Its hit area reaches 44 points around it
/// without taking more than the dot's own room. See Phone channel search in docs/spec.md.
struct SidebarFailureDot: View {
    let footer: SidebarFooter
    /// The server as the status line names it.
    let server: String
    let failure: String
    let openSettings: () -> Void
    @ViewState private var isPresented = false
    @ViewState private var opensSettings = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    static let size: CGFloat = 8
    /// How far the 44-point hit area reaches past the dot on each side.
    static let outset = (44 - size) / 2

    var status: String { "\(footer.verb) \(server)" }

    var body: some View {
        Button { isPresented = true } label: {
            mark
                .frame(width: Self.size, height: Self.size)
                .padding(Self.outset)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(-Self.outset)
        .accessibilityLabel(status)
        .accessibilityHint(failure)
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status).font(.headline)
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(ChannelInk.secondary)
                Button("Server Settings") {
                    opensSettings = true
                    isPresented = false
                }
                .frame(minHeight: 44)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding([.horizontal, .top])
            .padding(.bottom, 4)
            .frame(idealWidth: 300)
            .presentationCompactAdaptation(.popover)
            // The window can't present Settings while the popover is still leaving.
            .onDisappear {
                if opensSettings { opensSettings = false; openSettings() }
            }
        }
    }

    /// A problem never depends on color alone.
    @ViewBuilder private var mark: some View {
        if differentiateWithoutColor {
            Image(systemName: "exclamationmark.circle.fill").resizable().scaledToFit().foregroundStyle(footer.dot)
        } else {
            Circle().fill(footer.dot)
        }
    }
}
