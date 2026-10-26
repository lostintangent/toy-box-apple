import ChannelClient
import SwiftUI

struct ManagementError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct ManagementRecoveryNotice: View {
    let state: ChannelManagementRecoveryState
    let reviewTitle: String
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
                Button(reviewTitle, action: onReview).frame(minHeight: 44)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
