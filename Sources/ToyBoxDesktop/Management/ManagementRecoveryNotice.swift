import ChannelClient
import SwiftUI

struct ManagementRecoveryNotice: View {
    let state: ChannelManagementRecoveryState
    var reviewTitle: String?
    let onCheck: () -> Void
    var onReview: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .checking:
                ProgressView("Checking current server state")
                    .controlSize(.small)
            case .checkFailed(let message):
                ManagementError(message: "Current state could not be checked. \(message)")
                Button("Check Current State", action: onCheck)
            case .reconciled(let message):
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let reviewTitle {
                    Button(reviewTitle, action: onReview)
                }
            }
        }
    }
}
