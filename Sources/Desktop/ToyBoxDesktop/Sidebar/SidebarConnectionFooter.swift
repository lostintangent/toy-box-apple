import ChannelClient
import SwiftUI
import ToyBoxUI

/// The bottom of the sidebar: a status dot and how many servers there are, which opens Settings on
/// the Servers tab, and a trailing Open Screen. It has no background of its own, so rows scroll
/// beneath it under the system scroll edge effect. It never spins, since each server's header shows
/// its own load, and never shows an error message, since the dot marks a problem and its help reads
/// it. With no servers there's no footer.
struct SidebarConnectionFooter: View {
    let summary: SidebarFooter.Summary
    let openSettings: () -> Void
    /// File > Open Screen…, or nil without a server.
    let openScreen: (() -> Void)?
    @Environment(\.channelTextScale) private var scale

    /// The dot's leading edge, 4 points before the channel icons.
    private static let leading: CGFloat = 20
    /// The status line's capsule reaches this far past the dot on each side.
    private static let capsuleOutset: CGFloat = 6

    var body: some View {
        HStack {
            Button(action: openSettings) {
                HStack(spacing: 6) {
                    SidebarStatusDot(footer: summary.footer, spinning: false)
                    // Secondary from the button's style, and primary while it's lit.
                    Text(summary.title)
                        .font(.system(size: 11 * scale))
                        .lineLimit(1)
                }
                .padding(.horizontal, Self.capsuleOutset)
                .frame(height: 22 * scale)
                .contentShape(Capsule())
            }
            .buttonStyle(HoverFillButtonStyle(shape: Capsule()))
            .help(summary.help)
            .accessibilityLabel("Servers")
            .accessibilityValue(summary.accessibilityValue)
            .accessibilityHint(summary.accessibilityHint)
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
    }
}

extension SidebarFooter.Summary {
    /// The least healthy server, its readable failure on its own line while it has one, then where
    /// to change servers.
    var help: String {
        [status, failure, "Change servers in Settings."].compactMap { $0 }.joined(separator: "\n")
    }

    /// Like "1 server, connected".
    var accessibilityValue: String { "\(title), \(footer.accessibilityValue)" }

    /// The help's status and failure, which name the server.
    var accessibilityHint: String { [status, failure].compactMap { $0 }.joined(separator: "\n") }
}

/// Shows the spinner only once an attempt has lasted the delay, and crossfades back to the dot when
/// it resolves. A delay that ends just as its attempt does resumes after the next attempt has
/// written, so a canceled one never writes.
struct SpinnerDelay: ViewModifier {
    let busy: Bool
    var delay: Duration = .milliseconds(300)
    @Binding var spinning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.task(id: busy) {
            if busy { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
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
    /// A server's header help, which names its address, with the readable failure on its own line
    /// while there is one.
    func help(_ serverURL: String, failure: String?) -> String {
        ["\(verb) \(serverURL)", failure, "Change the server in Settings."].compactMap { $0 }.joined(separator: "\n")
    }
}
