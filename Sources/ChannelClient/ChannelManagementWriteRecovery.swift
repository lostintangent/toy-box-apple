import Observation

public enum ChannelManagementRecoveryState: Equatable, Sendable {
    case checking
    case checkFailed(String)
    case reconciled(String)

    public static func isRequired(after error: any Error) -> Bool {
        guard case ChannelAPIError.http(let status, _) = error else { return false }
        return status >= 500
    }

    public static let uncertaintyMessage = "The server reported an error, but the change may already have been applied. The request was not repeated."
}

@MainActor @Observable
public final class ChannelManagementWriteRecovery {
    public private(set) var error: String?
    public private(set) var state: ChannelManagementRecoveryState?
    public private(set) var result: ChannelManagementReconciliation?
    @ObservationIgnored private var isChecking = false

    public init() {}

    public var blocksWrites: Bool { state != nil }

    public func clearError() {
        guard !blocksWrites else { return }
        error = nil
    }

    @discardableResult
    public func record(_ error: any Error) -> Bool {
        if ChannelManagementRecoveryState.isRequired(after: error) {
            self.error = ChannelManagementRecoveryState.uncertaintyMessage
            state = .checking
            result = nil
            return true
        }
        self.error = error.localizedDescription
        return false
    }

    public func check(catalog: ChannelCatalogStore?, channelId: String?,
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

    public func finishReview() {
        guard case .reconciled = state else { return }
        error = nil
        state = nil
        result = nil
    }
}
