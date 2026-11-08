import SwiftUI
import ToyBoxUI

/// The catalog's failure at the bottom of the list. Kept rows show the reconnecting pill, which
/// retries when tapped. Otherwise it's the heading, the readable error, Retry and Settings.
struct ChannelSidebarFailure: View {
    let footer: SidebarFooter
    let error: String?
    let canRetry: Bool
    let retry: () -> Void
    let openSettings: () -> Void
    var showsSettingsButton = true

    var body: some View {
        if footer.isReconnecting, let heading = footer.heading, let error {
            ReconnectingNotice(subtitle: heading, failure: error, retry: retry)
                .padding(.vertical, 8)
        } else if let heading = footer.heading, let error {
            VStack(alignment: .leading, spacing: 4) {
                Label(heading, systemImage: "wifi.exclamationmark")
                    .font(.footnote.weight(.semibold))
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(ChannelInk.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 16) {
                    if canRetry {
                        Button("Retry", action: retry).frame(minHeight: 44)
                    }
                    if showsSettingsButton {
                        Button("Settings", action: openSettings).frame(minHeight: 44)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}
