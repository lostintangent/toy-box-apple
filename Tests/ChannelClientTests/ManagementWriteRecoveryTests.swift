import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

@MainActor
struct ManagementWriteRecoveryTests {
    @Test func aCommittedDeletionFollowedBy500IsReadBackWithoutReplayingDelete() async throws {
        let mock = MockTransport { request, _ in
            if request.httpMethod == "DELETE" {
                return MockResponse(status: 500, body: Data(#"{"error":"Management failed."}"#.utf8))
            }
            return try .json(ChannelCatalog(lead: testLeadProfile, channels: []))
        }
        let api = try mock.api()
        let recovery = ChannelManagementWriteRecovery()
        let catalog = ChannelCatalogStore(api: api)
        do {
            try await api.deleteChannel(id: "deleted-channel")
            Issue.record("The fixture must report an uncertain deletion.")
        } catch {
            #expect(recovery.record(error))
        }
        #expect(recovery.blocksWrites)
        recovery.clearError()
        #expect(recovery.error == ChannelManagementRecoveryState.uncertaintyMessage)
        recovery.finishReview()
        #expect(recovery.blocksWrites)
        await recovery.check(catalog: catalog, channelId: "deleted-channel") { current in
            current.channelWasDeleted ? "The channel is absent." : "The channel is present."
        }
        #expect(recovery.result?.channelWasDeleted == true)
        #expect(recovery.state == .reconciled("The channel is absent."))
        #expect(recovery.blocksWrites)
        #expect(mock.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
                == ["DELETE /api/v1/channels/deleted-channel", "GET /api/v1/channels"])
    }

    @Test func failedReconciliationKeepsWritesBlockedUntilAnExplicitReview() async throws {
        let status = Mutex(500)
        let mock = MockTransport { _, _ in
            if status.withLock({ $0 }) == 500 {
                return MockResponse(status: 500, body: Data(#"{"error":"Management failed."}"#.utf8))
            }
            return try .json(ChannelCatalog(lead: testLeadProfile, channels: []))
        }
        let recovery = ChannelManagementWriteRecovery()
        let catalog = ChannelCatalogStore(api: try mock.api())
        recovery.record(ChannelAPIError.http(status: 500, message: "Management failed."))
        await recovery.check(catalog: catalog, channelId: nil) { _ in "Catalog refreshed." }
        guard case .checkFailed(let message) = recovery.state else {
            Issue.record("A failed read must not be presented as reconciliation.")
            return
        }
        #expect(message.contains("HTTP 500"))
        #expect(recovery.blocksWrites && recovery.result == nil)
        recovery.finishReview()
        #expect(recovery.blocksWrites)
        status.withLock { $0 = 200 }
        await recovery.check(catalog: catalog, channelId: nil) { _ in "Catalog refreshed." }
        #expect(recovery.blocksWrites && recovery.state == .reconciled("Catalog refreshed."))
        recovery.finishReview()
        #expect(!recovery.blocksWrites && recovery.error == nil && recovery.result == nil)
        #expect(mock.requests.map(\.httpMethod) == ["GET", "GET"])
    }

    @Test func domainRejectionsKeepTheirUserFacingMessageWithoutBlockingEditing() {
        let recovery = ChannelManagementWriteRecovery()
        let error = ChannelAPIError.http(status: 422, message: "The mention is already in use.")
        #expect(!recovery.record(error))
        #expect(!recovery.blocksWrites)
        #expect(recovery.error == error.localizedDescription)
        #expect(recovery.result == nil)
    }

    @Test func unexpectedManagementFailuresRequireAReadBeforeAnotherWrite() {
        #expect(ChannelManagementRecoveryState.isRequired(after: ChannelAPIError.http(status: 503, message: "Unavailable.")))
        #expect(!ChannelManagementRecoveryState.isRequired(after: ChannelAPIError.http(status: 404, message: "Not found.")))
        #expect(!ChannelManagementRecoveryState.isRequired(after: ChannelAPIError.invalidMessage("Invalid name.")))
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost])
    func aLostWriteOutcomeRequiresReconciliation(code: URLError.Code) async throws {
        let mock = MockTransport { request, _ in
            if request.httpMethod == "DELETE" { throw URLError(code) }
            return try .json(ChannelCatalog(lead: testLeadProfile, channels: []))
        }
        let api = try mock.api()
        let recovery = ChannelManagementWriteRecovery()
        let catalog = ChannelCatalogStore(api: api)
        do {
            try await api.deleteChannel(id: "deleted-channel")
            Issue.record("The fixture must lose the write's outcome.")
        } catch {
            #expect(recovery.record(error))
        }
        #expect(recovery.blocksWrites)
        #expect(recovery.error == ChannelManagementRecoveryState.uncertaintyMessage)
        recovery.finishReview()
        #expect(recovery.blocksWrites)
        await recovery.check(catalog: catalog, channelId: "deleted-channel") { current in
            current.channelWasDeleted ? "The channel is absent." : "The channel is present."
        }
        #expect(recovery.result?.channelWasDeleted == true)
        #expect(recovery.blocksWrites)
        recovery.finishReview()
        #expect(!recovery.blocksWrites)
        #expect(mock.requests.map(\.httpMethod) == ["DELETE", "GET"])
    }

    @Test(arguments: [URLError.Code.cannotConnectToHost, .notConnectedToInternet, .cannotFindHost, .badURL])
    func anUnsentRequestKeepsItsErrorWithoutBlockingAnotherAttempt(code: URLError.Code) {
        let recovery = ChannelManagementWriteRecovery()
        let error = URLError(code)
        #expect(!recovery.record(error))
        #expect(!recovery.blocksWrites)
        #expect(recovery.error == error.localizedDescription)
        #expect(recovery.result == nil)
    }

    @Test func bridgedURLSessionErrorsKeepTheirClassification() {
        #expect(ChannelManagementRecoveryState.isRequired(
            after: NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)))
        #expect(!ChannelManagementRecoveryState.isRequired(
            after: NSError(domain: "FixtureError", code: URLError.timedOut.rawValue)))
    }

    @Test func aMissingCatalogCannotUnblockWritesOrInventAReconciliation() async {
        let recovery = ChannelManagementWriteRecovery()
        recovery.record(ChannelAPIError.http(status: 500, message: "Failed."))
        await recovery.check(catalog: nil, channelId: "studio") { _ in
            Issue.record("A missing catalog cannot produce a summary.")
            return "Not a reconciliation."
        }
        #expect(recovery.state == .checkFailed("Connect to the server before checking this change."))
        #expect(recovery.blocksWrites && recovery.result == nil)
        recovery.finishReview()
        #expect(recovery.blocksWrites)
    }
}
