import ChannelClient
import SwiftUI
import ToyBoxUI

/// The bottom of the sidebar: the error block when there is one, then a status dot and the server,
/// which opens Settings, and a trailing Open Screen. It has no background of its own, so rows
/// scroll beneath it under the system scroll edge effect. It is also the sidebar's only progress
/// indicator.
struct SidebarConnectionFooter: View {
    let footer: SidebarFooter
    /// The first load or a View > Refresh the person chose is in flight. Background polling never is.
    let busy: Bool
    let serverURL: String
    let error: String?
    let openSettings: () -> Void
    /// File > Open Screen…, or nil without a server.
    let openScreen: (() -> Void)?
    /// An attempt that resolves sooner than this never shows the spinner.
    var spinnerDelay: Duration = .milliseconds(300)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var showsSpinner = false

    /// The leading edge the dot and the error block share, 4 points before the channel icons.
    static let leading: CGFloat = 20
    /// The status line's capsule reaches this far past the dot on each side.
    static let capsuleOutset: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let heading = footer.heading, let error {
                errorBlock(heading: heading, error: error)
                    .padding(.horizontal, Self.leading)
            }
            HStack {
                Button(action: openSettings) {
                    SidebarStatusLine(footer: footer, spinning: showsSpinner, serverURL: serverURL)
                }
                .buttonStyle(HoverFillButtonStyle(shape: Capsule()))
                .help("\(footer.verb) \(serverURL)\nChange the server in Settings.")
                .accessibilityLabel("Server")
                .accessibilityValue("\(SidebarFooter.server(serverURL)), \(footer.accessibilityValue)")
                Spacer(minLength: 0)
                Button("Open Screen", systemImage: "display") { openScreen?() }
                    .labelStyle(.iconOnly)
                    .symbolRenderingMode(.monochrome)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Open Screen (Command-O)")
                    .disabled(openScreen == nil)
            }
            .padding(.horizontal, Self.leading - Self.capsuleOutset)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: busy) {
            if busy {
                do { try await Task.sleep(for: spinnerDelay) } catch { return }
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsSpinner = busy }
        }
    }

    private func errorBlock(heading: String, error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(heading, systemImage: "wifi.exclamationmark")
                .font(.caption.weight(.medium))
            Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The dot, or a spinner in its slot, then the server. The 10-point mini spinner centers on the
/// 7-point dot and overhangs it unclipped, so the host never moves.
struct SidebarStatusLine: View {
    let footer: SidebarFooter
    let spinning: Bool
    let serverURL: String
    @Environment(\.channelTextScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(footer.dot)
                .frame(width: 7, height: 7)
                .opacity(spinning ? 0 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: footer)
                .overlay {
                    if spinning {
                        ProgressView().controlSize(.mini).fixedSize().transition(.opacity)
                    }
                }
            // Secondary from the button's style, and primary while it's lit.
            Text(SidebarFooter.server(serverURL))
                .font(.system(size: 11 * scale))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, SidebarConnectionFooter.capsuleOutset)
        .frame(height: 22 * scale)
        .contentShape(Capsule())
    }
}
