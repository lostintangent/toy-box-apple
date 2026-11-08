import SwiftUI
import ToyBoxUI

/// Floating glass capsule for kept content whose stream dropped, which stays put while it
/// reconnects on its own. VoiceOver reads both lines as one element, with the readable failure as
/// its hint. With `retry`, the whole capsule is a button that tries again at once.
struct ReconnectingNotice: View {
    let subtitle: String
    let failure: String
    var retry: (() -> Void)?

    var body: some View {
        Group {
            if let retry {
                Button(action: retry) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
        .glassEffect(retry == nil ? .regular : .regular.interactive(), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityHint(failure)
    }

    private var content: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 0) {
                Text("Reconnecting to server").font(.footnote.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(ChannelInk.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(.capsule)
    }
}
