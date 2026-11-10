import ChannelClient
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

/// A failing server's notice under its header when the list shows several: the pill's words while
/// its rows stay, otherwise the heading and error, each with Retry.
struct ChannelSidebarServerNotice: View {
    let catalog: ChannelCatalogStore
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        if let heading = footer.heading, let error = catalog.phase.message {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    // Not a Label, whose icon the list would tint.
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.exclamationmark").accessibilityHidden(true)
                        Text(footer.isReconnecting ? "Reconnecting to server" : heading)
                    }
                    .font(.footnote.weight(.semibold))
                    Text(footer.isReconnecting ? heading : error)
                        .font(.footnote)
                        .foregroundStyle(ChannelInk.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint(footer.isReconnecting ? error : "")
                Spacer(minLength: 0)
                if canRetry {
                    // Borderless, so only Retry retries and it takes the accent, not the whole row.
                    Button("Retry", action: retry).buttonStyle(.borderless).frame(minHeight: 44)
                }
            }
            .listRowSeparator(.hidden)
        }
    }
}
