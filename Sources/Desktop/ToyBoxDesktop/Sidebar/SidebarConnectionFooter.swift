import ChannelClient
import SwiftUI
import ToyBoxUI

/// The bottom of the sidebar: a status dot and the server, which opens Settings on the Servers tab,
/// and a trailing Open Screen. It has no background of its own, so rows scroll beneath it under the
/// system scroll edge effect. With one server, it is also the sidebar's only progress indicator. It
/// never shows an error message, since the dot marks a problem and its help reads it.
struct SidebarConnectionFooter: View {
    let status: Status
    /// The first load or a View > Refresh the person chose is in flight. Background polling never is.
    let busy: Bool
    let openSettings: () -> Void
    /// File > Open Screen…, or nil without a server.
    let openScreen: (() -> Void)?
    /// An attempt that resolves sooner than this never shows the spinner.
    var spinnerDelay: Duration = .milliseconds(300)
    @ViewState private var showsSpinner = false

    /// The dot's leading edge, 4 points before the channel icons.
    static let leading: CGFloat = 20
    /// The status line's capsule reaches this far past the dot on each side.
    static let capsuleOutset: CGFloat = 6

    var body: some View {
        HStack {
            Button(action: openSettings) {
                SidebarStatusLine(footer: status.footer, spinning: showsSpinner, title: status.title)
            }
            .buttonStyle(HoverFillButtonStyle(shape: Capsule()))
            .help(status.help)
            .accessibilityLabel(status.accessibilityLabel)
            .accessibilityValue(status.accessibilityValue)
            .accessibilityHint(status.failure ?? "")
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
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SpinnerDelay(busy: busy, delay: spinnerDelay, spinning: $showsSpinner))
    }

    /// One server's address, or several servers summed up, as Connection footer describes.
    enum Status {
        /// One server, with its readable failure while it has one.
        case server(SidebarFooter, url: String, failure: String?)
        case servers(SidebarFooter.Summary)

        /// Several servers leave theirs to their own headers.
        var failure: String? {
            guard case .server(_, _, let failure) = self else { return nil }
            return failure
        }

        var footer: SidebarFooter {
            switch self {
            case .server(let footer, _, _): footer
            case .servers(let summary): summary.footer
            }
        }

        var title: String {
            switch self {
            case .server(_, let url, _): SidebarFooter.server(url)
            case .servers(let summary): summary.title
            }
        }

        var help: String {
            switch self {
            case .server(let footer, let url, let failure): footer.help(url, failure: failure)
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
            case .server(let footer, let url, _): "\(SidebarFooter.server(url)), \(footer.accessibilityValue)"
            case .servers(let summary): summary.status
            }
        }
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
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        mark
            .frame(width: 7, height: 7)
            .opacity(spinning ? 0 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: footer)
            .overlay {
                if spinning {
                    ProgressView().controlSize(.mini).fixedSize().transition(.opacity)
                }
            }
    }

    /// A problem never depends on color alone.
    @ViewBuilder private var mark: some View {
        if differentiateWithoutColor && footer.isFailing {
            Image(systemName: "exclamationmark.circle.fill").resizable().scaledToFit().foregroundStyle(footer.dot)
        } else {
            Circle().fill(footer.dot)
        }
    }
}

extension SidebarFooter {
    /// The status line's help, which a server's header shares, with the readable failure on its own
    /// line while there is one.
    func help(_ serverURL: String, failure: String?) -> String {
        ["\(verb) \(serverURL)", failure, "Change the server in Settings."].compactMap { $0 }.joined(separator: "\n")
    }
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
