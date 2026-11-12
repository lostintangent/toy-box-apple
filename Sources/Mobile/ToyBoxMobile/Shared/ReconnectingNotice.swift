import SwiftUI
import ToyBoxUI

/// Floating glass capsule for kept content whose stream dropped, which stays put while it
/// reconnects on its own. VoiceOver reads both lines as one element, with the readable failure as
/// its hint.
struct ReconnectingNotice: View {
    let subtitle: String
    let failure: String

    var body: some View {
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
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityHint(failure)
    }
}
