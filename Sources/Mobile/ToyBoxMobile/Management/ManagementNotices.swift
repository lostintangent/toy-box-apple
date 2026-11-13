import ChannelClient
import SwiftUI
import ToyBoxUI

struct ManagementError: View {
    let message: String
    var systemImage = "exclamationmark.triangle"

    var body: some View {
        Label {
            Text(message).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.red)
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct ManagementConnectionNotice: View {
    let store: ChannelStore

    var body: some View {
        Label(store.phase == .deleted ? "This channel was deleted."
              : "Your edits are kept. Save them when the channel connects.",
              systemImage: "wifi.exclamationmark")
            .font(.footnote)
            .foregroundStyle(ChannelInk.secondary)
    }
}
