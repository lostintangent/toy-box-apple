import ChannelClient
import SwiftUI
import ToyBoxUI

/// The bottom of the sidebar: the error block when there is one, then a status dot and the server,
/// which opens Settings on the Servers tab, and a trailing Open Screen. It has no background of its
/// own, so rows scroll beneath it under the system scroll edge effect. With one server, it is also
/// the sidebar's only progress indicator.
struct SidebarConnectionFooter: View {
    let status: Status
    /// The first load or a View > Refresh the person chose is in flight. Background polling never is.
    let busy: Bool
    /// One server's failure. Several servers show theirs under their own headers.
    let error: String?
    let openSettings: () -> Void
    /// File > Open Screen…, or nil without a server.
    let openScreen: (() -> Void)?
    /// An attempt that resolves sooner than this never shows the spinner.
    var spinnerDelay: Duration = .milliseconds(300)
    @ViewState private var showsSpinner = false

    /// The leading edge the dot and the error block share, 4 points before the channel icons.
    static let leading: CGFloat = 20
    /// The status line's capsule reaches this far past the dot on each side.
    static let capsuleOutset: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .server(let footer, _) = status, let heading = footer.heading, let error {
                SidebarErrorBlock(heading: heading, error: error)
                    .padding(.horizontal, Self.leading)
            }
            HStack {
                Button(action: openSettings) {
                    SidebarStatusLine(footer: status.footer, spinning: showsSpinner, title: status.title)
                }
                .buttonStyle(HoverFillButtonStyle(shape: Capsule()))
                .help(status.help)
                .accessibilityLabel(status.accessibilityLabel)
                .accessibilityValue(status.accessibilityValue)
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
        .modifier(SpinnerDelay(busy: busy, delay: spinnerDelay, spinning: $showsSpinner))
    }

    /// One server's address, or several servers summed up, as Connection footer describes.
    enum Status {
        case server(SidebarFooter, url: String)
        case servers(SidebarFooter.Summary)

        var footer: SidebarFooter {
            switch self {
            case .server(let footer, _): footer
            case .servers(let summary): summary.footer
            }
        }

        var title: String {
            switch self {
            case .server(_, let url): SidebarFooter.server(url)
            case .servers(let summary): summary.title
            }
        }

        var help: String {
            switch self {
            case .server(let footer, let url): footer.help(url)
            case .servers(let summary): "\(summary.status)\nChange servers in Settings."
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .server: "Server"
            case .servers: "Servers"
            }
        }

        var accessibilityValue: String {
            switch self {
            case .server(let footer, let url): "\(SidebarFooter.server(url)), \(footer.accessibilityValue)"
            case .servers(let summary): summary.status
            }
        }
    }
}

/// A failing server's heading over its readable failure. It has no buttons, since the catalog
/// keeps retrying on its own.
struct SidebarErrorBlock: View {
    let heading: String
    let error: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Not a Label, which a sidebar list would restyle as a row's icon and title.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "wifi.exclamationmark").accessibilityHidden(true)
                Text(heading)
            }
            .font(.caption.weight(.medium))
            Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shows the spinner only once an attempt has lasted the delay, and crossfades back to the dot when
/// it resolves.
struct SpinnerDelay: ViewModifier {
    let busy: Bool
    var delay: Duration = .milliseconds(300)
    @Binding var spinning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.task(id: busy) {
            if busy {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { spinning = busy }
        }
    }
}

/// The 7-point status dot, or a spinner in its slot. The 10-point mini spinner centers on the dot
/// and overhangs it unclipped, so what follows never moves.
struct SidebarStatusDot: View {
    let footer: SidebarFooter
    let spinning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(footer.dot)
            .frame(width: 7, height: 7)
            .opacity(spinning ? 0 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: footer)
            .overlay {
                if spinning {
                    ProgressView().controlSize(.mini).fixedSize().transition(.opacity)
                }
            }
    }
}

extension SidebarFooter {
    /// The status line's help, which a server's header shares.
    func help(_ serverURL: String) -> String { "\(verb) \(serverURL)\nChange the server in Settings." }
}

/// The dot, or a spinner in its slot, then the server or how many there are.
struct SidebarStatusLine: View {
    let footer: SidebarFooter
    let spinning: Bool
    let title: String
    @Environment(\.channelTextScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            SidebarStatusDot(footer: footer, spinning: spinning)
            // Secondary from the button's style, and primary while it's lit.
            Text(title)
                .font(.system(size: 11 * scale))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, SidebarConnectionFooter.capsuleOutset)
        .frame(height: 22 * scale)
        .contentShape(Capsule())
    }
}
