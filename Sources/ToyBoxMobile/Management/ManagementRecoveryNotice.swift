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

struct ManagementRecoveryNotice: View {
    let state: ChannelManagementRecoveryState
    let reviewTitle: String?
    let onCheck: () -> Void
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .checking:
                ProgressView("Checking current server values…")
            case .checkFailed(let message):
                Text(message).font(.footnote)
                Button("Check Current Server Values", action: onCheck).frame(minHeight: 44)
            case .reconciled(let message):
                Text(message).font(.footnote)
                if let reviewTitle { Button(reviewTitle, action: onReview).frame(minHeight: 44) }
            }

        }
        .fixedSize(horizontal: false, vertical: true)
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
