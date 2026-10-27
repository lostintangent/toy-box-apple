import ChannelClient
import ChannelKit
import Foundation
import Synchronization
import Testing
import UserNotifications
@testable import ToyBoxMobile
@testable import ToyBoxMobileIntegrations

#if DEBUG && targetEnvironment(simulator)
@Suite("Mobile notification proof", .serialized)
@MainActor
struct NotificationProofTests {
    @Test func theRequestLaunchActionUsesTheExistingOneStepPath() async throws {
        let fixture = try ProofFixture()
        defer { fixture.close() }
        try await fixture.notifications.runProofNotificationAction(.request, enrich: fixture.enrich)
        #expect(OfflineProofProtocol.requests == 1)
        #expect(fixture.capture.payloads.count == 1)
        #expect(fixture.capture.notices.count == 1)
    }

    @Test func launchActionsPersistRoutingAcrossNotificationInstancesWithoutAnOfflineCatalogLookup() async throws {
        let fixture = try ProofFixture()
        defer { fixture.close() }
        try await fixture.notifications.runProofNotificationAction(
            .prepareOffline, directory: fixture.directory, enrich: fixture.enrich)
        let prepared = try ChannelNotifications.PreparedProofNotification.read(directory: fixture.directory)
        #expect(prepared.payload == fixture.capture.payloads.first)
        #expect(fixture.capture.notices.isEmpty)
        let relaunched = fixture.relaunchedNotifications()
        OfflineProofProtocol.setOffline()
        try await relaunched.runProofNotificationAction(
            .deliverOffline, directory: fixture.directory, enrich: fixture.enrich)
        #expect(OfflineProofProtocol.requests == 1)
        #expect(fixture.capture.payloads == [prepared.payload, prepared.payload])
        #expect(fixture.capture.notices.count == 1)
    }

    @Test func deliveringBeforePreparationFailsWithoutFetchingOrScheduling() async throws {
        let fixture = try ProofFixture()
        defer { fixture.close() }
        await #expect(throws: (any Error).self) {
            try await fixture.notifications.runProofNotificationAction(
                .deliverOffline, directory: fixture.directory, enrich: fixture.enrich)
        }
        #expect(OfflineProofProtocol.requests == 0)
        #expect(fixture.capture.payloads.isEmpty)
        #expect(fixture.capture.notices.isEmpty)
    }

    @Test func stagedDeliveryDoesNotPreflightTheCatalogAfterTheServerGoesOffline() async throws {
        let fixture = try ProofFixture()
        defer { fixture.close() }
        let prepared = try await fixture.notifications.prepareProofNotification(.request, enrich: fixture.enrich)
        #expect(fixture.capture.payloads == [prepared.payload])
        #expect(OfflineProofProtocol.requests == 1)
        OfflineProofProtocol.setOffline()
        try await fixture.notifications.schedulePreparedProofNotification(prepared, enrich: fixture.enrich)
        #expect(OfflineProofProtocol.requests == 1)
        #expect(fixture.capture.payloads == [prepared.payload, prepared.payload])
        let notice = try #require(fixture.capture.notices.first)
        #expect(fixture.capture.notices.count == 1)
        #expect(try ChannelPushPayload(userInfo: notice.content.userInfo) == prepared.payload)
        let trigger = try #require(notice.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(trigger.timeInterval == 30)
        #expect(!trigger.repeats)
    }

    @Test(arguments: [ChannelPushPayload.Kind.request, .completion])
    func existingOneStepControlsStillEnrichOnceAndSchedule(kind: ChannelPushPayload.Kind) async throws {
        let fixture = try ProofFixture()
        defer { fixture.close() }
        try await fixture.notifications.scheduleProofNotification(kind, enrich: fixture.enrich)
        #expect(OfflineProofProtocol.requests == 1)
        #expect(fixture.capture.payloads.count == 1)
        #expect(fixture.capture.payloads.first?.kind == kind)
        #expect(fixture.capture.notices.count == 1)
        #expect(fixture.capture.notices.first?.content.categoryIdentifier == kind.rawValue)
    }

    @Test func aServerChangeDuringPreparationCannotLeaveAStagedOldRequest() async throws {
        let fixture = try ProofFixture()
        defer { fixture.close() }
        await #expect(throws: (any Error).self) {
            try await fixture.notifications.prepareProofNotification(.request) { payload in
                try fixture.registration.select(api: ChannelAPI(serverURL: "https://other.example"))
                return fixture.enrich(payload)
            }
        }
        #expect(fixture.capture.notices.isEmpty)
    }

    @Test func aStalePreparedRegistrationIsRejectedBeforeEnrichment() async throws {
        let fixture = try ProofFixture()
        defer { fixture.close() }
        let prepared = try await fixture.notifications.prepareProofNotification(.request, enrich: fixture.enrich)
        try fixture.registration.select(api: ChannelAPI(serverURL: "https://other.example"))
        await #expect(throws: (any Error).self) {
            try await fixture.notifications.schedulePreparedProofNotification(prepared, enrich: fixture.enrich)
        }
        #expect(fixture.capture.payloads.count == 1)
        #expect(fixture.capture.notices.isEmpty)
    }

    @Test func aServerChangeDuringPreparedEnrichmentCannotScheduleOldRouting() async throws {
        let fixture = try ProofFixture()
        defer { fixture.close() }
        let prepared = try await fixture.notifications.prepareProofNotification(.request, enrich: fixture.enrich)
        await #expect(throws: (any Error).self) {
            try await fixture.notifications.schedulePreparedProofNotification(prepared) { payload in
                try fixture.registration.select(api: ChannelAPI(serverURL: "https://other.example"))
                return fixture.enrich(payload)
            }
        }
        #expect(fixture.capture.notices.isEmpty)
    }

    @Test func aSchedulingFailureIsReportedRatherThanClaimingDelivery() async throws {
        let fixture = try ProofFixture()
        defer { fixture.close() }
        let prepared = try await fixture.notifications.prepareProofNotification(.request, enrich: fixture.enrich)
        fixture.capture.failDelivery = true
        await #expect(throws: (any Error).self) {
            try await fixture.notifications.schedulePreparedProofNotification(prepared, enrich: fixture.enrich)
        }
        #expect(fixture.capture.notices.isEmpty)
    }

    @Test func preparationNeverLooksUpANonDemoServer() async throws {
        let fixture = try ProofFixture()
        defer { fixture.close() }
        let api = try ChannelAPI(serverURL: "https://other.example", session: fixture.session)
        try fixture.registration.select(api: api)
        fixture.notifications.configure(api: api)
        await #expect(throws: (any Error).self) {
            try await fixture.notifications.prepareProofNotification(.request, enrich: fixture.enrich)
        }
        #expect(OfflineProofProtocol.requests == 0)
        #expect(fixture.capture.payloads.isEmpty)
        #expect(fixture.capture.notices.isEmpty)
    }
}

@MainActor
private final class ProofFixture {
    final class Capture {
        var notices: [UNNotificationRequest] = []
        var payloads: [ChannelPushPayload] = []
        var failDelivery = false
    }

    let capture: Capture
    let notifications: ChannelNotifications
    let registration: MobileNotificationRegistration
    let session: URLSession
    let directory: URL
    private let api: ChannelAPI
    private let defaults: UserDefaults
    private let defaultsName: String

    init() throws {
        OfflineProofProtocol.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notification-proof-\(UUID())")
        defaultsName = "notification-proof-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProofProtocol.self]
        session = URLSession(configuration: configuration)
        registration = MobileNotificationRegistration(
            store: try MobilePushRegistrationStore(directory: directory),
            environment: .sandbox, requestToken: {}, register: { _, _ in }, remove: { _, _ in })
        api = try ChannelAPI(serverURL: "http://127.0.0.1:3210", session: session)
        try registration.select(api: api)
        let capture = Capture()
        self.capture = capture
        notifications = ChannelNotifications(defaults: defaults, registration: registration, addNotice: {
            if capture.failDelivery { throw CocoaError(.featureUnsupported) }
            capture.notices.append($0)
        })
        notifications.configure(api: api)
    }

    func relaunchedNotifications() -> ChannelNotifications {
        let capture = capture
        let notifications = ChannelNotifications(
            defaults: defaults, registration: registration, addNotice: { capture.notices.append($0) })
        notifications.configure(api: api)
        return notifications
    }

    func enrich(_ payload: ChannelPushPayload) -> UNNotificationContent {
        capture.payloads.append(payload)
        let content = UNMutableNotificationContent()
        content.title = "Studio"
        content.body = NotificationText.waitingBody
        content.categoryIdentifier = payload.kind.rawValue
        content.userInfo = payload.userInfo
        return content
    }

    func close() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: defaultsName)
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Could not clean notification proof fixture: \(error)") }
    }
}

private final class OfflineProofProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var requests = 0
        var isOffline = false
    }

    private static let state = Mutex(State())
    static var requests: Int { state.withLock { $0.requests } }
    static func setOffline() { state.withLock { $0.isOffline = true } }
    static func reset() { state.withLock { $0 = State() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let offline = Self.state.withLock {
            $0.requests += 1
            return $0.isOffline
        }
        if offline {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            let catalog = ChannelCatalog(
                lead: .init(name: "Lead", role: "Coordinator", avatar: .init(mark: "M4 12H20", color: "#123456")),
                channels: [.init(id: "studio", name: "Studio", model: .init(provider: "test", name: "test"),
                                 completedSequence: 22, requestSequence: 15, updatedAt: "2026-10-27T00:00:00Z")])
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(catalog))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
#endif
