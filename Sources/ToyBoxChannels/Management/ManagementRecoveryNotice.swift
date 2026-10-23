import ChannelClient
import Observation
import SwiftUI

enum ManagementRecoveryState: Equatable {
    case checking
    case checkFailed(String)
    case reconciled(String)

    static func isRequired(after error: any Error) -> Bool {
        guard case ChannelAPIError.http(let status, _) = error else { return false }
        return status >= 500
    }

    static let uncertaintyMessage = "The server reported an error, but the change may already have been applied. The request was not repeated."
}

@MainActor @Observable
final class ManagementWriteRecovery {
    private(set) var error: String?
    private(set) var state: ManagementRecoveryState?
    private(set) var result: ChannelManagementReconciliation?
    @ObservationIgnored private var isChecking = false

    var blocksWrites: Bool { state != nil }

    func clearError() {
        guard !blocksWrites else { return }
        error = nil
    }

    @discardableResult
    func record(_ error: any Error) -> Bool {
        if ManagementRecoveryState.isRequired(after: error) {
            self.error = ManagementRecoveryState.uncertaintyMessage
            state = .checking
            result = nil
            return true
        }
        self.error = error.localizedDescription
        return false
    }

    func check(catalog: ChannelCatalogStore?, channelId: String?,
               summary: (ChannelManagementReconciliation) -> String) async {
        guard !isChecking else { return }
        isChecking = true
        state = .checking
        result = nil
        defer { isChecking = false }
        guard let catalog else {
            state = .checkFailed("Connect to the server before checking this change.")
            return
        }
        do {
            let current = try await catalog.reconcileManagementWrite(channelId: channelId)
            result = current
            state = .reconciled(summary(current))
        } catch {
            state = .checkFailed(error.localizedDescription)
        }
    }

    func finishReview() {
        guard case .reconciled = state else { return }
        error = nil
        state = nil
        result = nil
    }
}

struct ManagementRecoveryNotice: View {
    let state: ManagementRecoveryState
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
