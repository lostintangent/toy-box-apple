import ChannelClient
import ChannelKit
import Foundation
import Intents
import Testing
import UIKit
import UserNotifications
@testable import ToyBoxMobileIntegrations

struct MobileNotificationEnricherTests {
    @Test(arguments: [0, 3])
    @MainActor func requestIntentsIdentifyTheLocalRecipientAndTheRealChannelGroup(memberCount: Int) async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://server.test")
        var catalog = Self.catalog()
        catalog.members = (0..<memberCount).map { .init(id: "member-\($0)", name: "Member \($0)", channelId: "studio") }
        catalog.members.append(.init(id: "other", name: "Other", channelId: "other-channel"))
        let fetched = catalog
        let png = try #require(UIImage(systemName: "star.fill")?.pngData())
        let enricher = MobileNotificationEnricher(
            directory: directory, avatarPNG: { _ in png }, fetch: { _, _ in .init(catalog: fetched) })
        enricher.start(Self.payload(registration: registration)) { _ in }
        let work = try #require(enricher.work)
        await work.value
        let intent = try #require(enricher.pendingIntent)
        #expect(intent.speakableGroupName?.spokenPhrase == "Studio")
        #expect(intent.conversationIdentifier == "\(registration.serverURL):studio")
        #expect(intent.recipients?.count == 1)
        #expect(intent.recipients?.first?.isMe == true)
        let metadata = try #require(intent.donationMetadata as? INSendMessageIntentDonationMetadata)
        #expect(metadata.recipientCount == memberCount + 1)
        #expect(intent.sender?.displayName == catalog.lead.name)
        #expect(intent.image(forParameterNamed: \.speakableGroupName) != nil)
    }

    @Test(arguments: [ChannelPushPayload.Kind.request, .completion])
    @MainActor func resolvedAlertsUseTheSharedTextAndRealCatalogIdentity(kind: ChannelPushPayload.Kind) async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://server.test")
        let catalog = Self.catalog()
        let question = Self.question()
        var rendered: [ChannelAgent] = []
        var events: [String] = []
        let enricher = MobileNotificationEnricher(directory: directory, avatarPNG: { agent in
            rendered.append(agent)
            return nil
        }, fetch: { api, payload in
            #expect(api.baseURL.absoluteString == registration.serverURL)
            #expect(payload.kind == kind)
            return .init(catalog: catalog, messages: [question])
        }, reloadWidgets: { events.append("reload") })
        var delivered: UNNotificationContent?
        enricher.start(Self.payload(kind: kind, registration: registration)) {
            delivered = $0
            events.append("delivered")
        }
        let work = try #require(enricher.work)
        await work.value
        enricher.expire()
        #expect(events == ["reload", "delivered"])
        let content = try #require(delivered)
        #expect(content.title == "Studio")
        #expect(content.categoryIdentifier == kind.rawValue)
        #expect(content.threadIdentifier == "\(registration.serverURL):studio")
        #expect(content.userInfo["registrationID"] as? String == registration.registrationID)
        #expect(content.interruptionLevel == .active)
        switch kind {
        case .request:
            let lead = ChannelAgent.lead(id: "studio", profile: catalog.lead)
            #expect(rendered == [lead])
            #expect(content.subtitle == NotificationText.subtitle(requester: catalog.lead.name))
            #expect(content.body == NotificationText.requestBody(question, agents: [lead]))
            #expect(content.body.count <= 400)
            #expect(!content.body.contains("**"))
            #expect(content.userInfo["handle"] as? String == agentHandleFromName(catalog.lead.name))
        case .completion:
            #expect(rendered.isEmpty)
            #expect(content.subtitle.isEmpty)
            #expect(content.body == NotificationText.completionBody(tasks: catalog.channels[0].tasks))
            #expect(content.userInfo["handle"] == nil)
        }
        let cached = try MobileNotificationCatalogCache.read(directory: directory)
        #expect(cached.registration == registration)
        #expect(cached.catalog == catalog)
    }

    @Test @MainActor func theDeadlineDeliversCachedIdentityOnceWithoutWaitingForCancelledWork() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://server.test")
        let catalog = Self.catalog()
        try MobileNotificationCatalogCache(registration: registration, catalog: catalog).write(directory: directory)
        let network = EnrichmentGate()
        let timer = EnrichmentGate()
        let timerStarted = EnrichmentGate()
        let didDeliver = EnrichmentGate()
        var rendered: [ChannelAgent] = []
        let enricher = MobileNotificationEnricher(directory: directory, avatarPNG: { agent in
            rendered.append(agent)
            return nil
        }, fetch: { _, _ in
            await network.wait()
            #expect(Task.isCancelled)
            return .init(catalog: catalog, messages: [Self.question()])
        }, pause: { duration in
            #expect(duration <= .seconds(3))
            #expect(duration >= .zero)
            await timerStarted.open()
            await timer.wait()
        })
        var delivered: [UNNotificationContent] = []
        enricher.start(Self.payload(registration: registration)) {
            delivered.append($0)
            Task { await didDeliver.open() }
        }
        let work = try #require(enricher.work)
        await timerStarted.wait()
        #expect(delivered.isEmpty)
        await timer.open()
        await didDeliver.wait()
        #expect(MobileNotificationEnricher.contentDeadline == .seconds(3))
        #expect(delivered.count == 1)
        #expect(delivered.first?.title == "Studio")
        #expect(delivered.first?.body == NotificationText.waitingBody)
        #expect(delivered.first?.subtitle == NotificationText.subtitle(requester: catalog.lead.name))
        #expect(rendered.map(\.name) == [catalog.lead.name])
        await network.open()
        await work.value
        enricher.expire()
        #expect(delivered.count == 1)
    }

    @Test @MainActor func anUnreachableServerUsesGenericCompletionTextRatherThanCachedTaskDetails() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://server.test")
        try MobileNotificationCatalogCache(registration: registration, catalog: Self.catalog()).write(directory: directory)
        let enricher = MobileNotificationEnricher(directory: directory, avatarPNG: { _ in nil }, fetch: { _, _ in
            throw URLError(.cannotConnectToHost)
        })
        var delivered: UNNotificationContent?
        enricher.start(Self.payload(kind: .completion, registration: registration)) { delivered = $0 }
        let work = try #require(enricher.work)
        await work.value
        #expect(delivered?.title == "Studio")
        #expect(delivered?.body == NotificationText.completionBody(tasks: []))
        #expect(delivered?.categoryIdentifier == ChannelNotificationCategory.completion)
    }

    @Test @MainActor func aDifferentRegistrationGetsNoIdentityActionRoutingOrNetworkLookup() throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://server.test")
        try MobileNotificationCatalogCache(registration: registration, catalog: Self.catalog()).write(directory: directory)
        let enricher = MobileNotificationEnricher(directory: directory, avatarPNG: { _ in
            Issue.record("A mismatched notification must not resolve identity.")
            return nil
        }, fetch: { _, _ in
            Issue.record("A mismatched notification must not fetch.")
            throw CancellationError()
        }, reloadWidgets: {
            Issue.record("A mismatched notification must not request a widget reload.")
        })
        var delivered: UNNotificationContent?
        enricher.start(.init(kind: .request, channelID: "studio", sequence: 15, registrationID: UUID().uuidString)) {
            delivered = $0
        }
        #expect(enricher.work == nil)
        #expect(delivered?.title == "Toy Box")
        #expect(delivered?.userInfo.isEmpty == true)
        #expect(delivered?.categoryIdentifier.isEmpty == true)
        #expect(delivered?.threadIdentifier.isEmpty == true)
    }

    @Test @MainActor func aServerChangeDuringLookupCannotDeliverOrCacheTheOldServersQuestion() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://server.test")
        let network = EnrichmentGate()
        let enricher = MobileNotificationEnricher(directory: directory, avatarPNG: { _ in nil }, fetch: { _, _ in
            await network.wait()
            return .init(catalog: Self.catalog(), messages: [Self.question()])
        })
        var delivered: UNNotificationContent?
        enricher.start(Self.payload(registration: registration)) { delivered = $0 }
        let work = try #require(enricher.work)
        try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://other.test")
        await network.open()
        await work.value
        #expect(delivered?.title == "Toy Box")
        #expect(delivered?.userInfo.isEmpty == true)
        #expect(delivered?.categoryIdentifier.isEmpty == true)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(MobileNotificationCatalogCache.fileName).path))
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tbm-enrichment-\(UUID())")
    }

    private static func payload(kind: ChannelPushPayload.Kind = .request,
                                registration: MobilePushRegistration) -> ChannelPushPayload {
        .init(kind: kind, channelID: "studio", sequence: 15, registrationID: registration.registrationID)
    }

    private static func catalog() -> ChannelCatalog {
        .init(lead: .init(name: "Server Lead", role: "Coordinates",
                         avatar: .init(mark: "M4 12L12 4L20 12", color: "#327785")),
              channels: [.init(id: "studio", name: "Studio", model: .init(provider: "copilot", name: "model"),
                               tasks: [.init(id: "one", title: "Ship the client", status: "done")],
                               updatedAt: "2026-10-27T07:30:00Z")])
    }

    private static func question() -> ChannelMessage {
        .init(id: "question", sequence: 15, timestamp: "2026-10-27T07:30:00Z", sender: .agent("studio"),
              content: .text("@server-lead **Ready to ship?** " + String(repeating: "A measured question. ", count: 40)))
    }
}

private actor EnrichmentGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
