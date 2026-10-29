import SwiftUI
import ToyBoxUI

struct ChannelSidebarFailure: View {
    let footer: SidebarFooter
    let error: String?
    let canRetry: Bool
    let retry: () -> Void
    let openSettings: () -> Void
    var showsSettingsButton = true

    var body: some View {
        if let heading = footer.heading, let error {
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
