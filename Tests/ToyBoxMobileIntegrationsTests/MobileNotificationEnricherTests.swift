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
        var donated: INSendMessageIntent?
        let enricher = MobileNotificationEnricher(
            directory: directory, avatarPNG: { _ in png }, fetch: { _, _ in .init(catalog: fetched) },
            donate: { donated = $0 })
        enricher.start(Self.request(registration: registration)) { _ in }
        let work = try #require(enricher.work)
        await work.value
        let intent = try #require(donated)
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
    @MainActor func resolvedAlertsEnrichTheOriginalWithSharedTextAndRealIdentity(kind: ChannelPushPayload.Kind) async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://server.test")
        let catalog = Self.catalog()
        let question = Self.question()
        let original = Self.request(kind: kind, registration: registration)
        var rendered: [ChannelAgent] = []
        var events: [String] = []
        let enricher = MobileNotificationEnricher(directory: directory, avatarPNG: { agent in
            rendered.append(agent)
            return nil
        }, fetch: { api, payload in
            #expect(api.baseURL.absoluteString == registration.serverURL)
            #expect(payload.kind == kind)
            return .init(catalog: catalog, messages: [question])
        }, reloadWidgets: { events.append("reload") }, donate: { _ in })
        var delivered: UNNotificationContent?
        enricher.start(original) { delivered = $0; events.append("delivered") }
        let work = try #require(enricher.work)
        await work.value
        enricher.expire()
        #expect(events == ["reload", "delivered"])
        let content = try #require(delivered)
        #expect(content.title == "Studio")
        #expect(content.categoryIdentifier == kind.rawValue)
        #expect(content.threadIdentifier == "\(registration.serverURL):studio")
        #expect(content.userInfo["registrationID"] as? String == registration.registrationID)
        #expect(content.userInfo["extra"] as? String == "untouched")
        #expect(content.badge == original.content.badge)
        #expect(original.content.title == "Toy Box")
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
    }

    @Test @MainActor func theDeadlineDeliversTheOriginalOnceWithoutWaitingForCancelledWork() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://server.test")
        let original = Self.request(registration: registration)
        let network = EnrichmentGate(), timer = EnrichmentGate(), timerStarted = EnrichmentGate(), didDeliver = EnrichmentGate()
        let enricher = MobileNotificationEnricher(directory: directory, avatarPNG: { _ in
            Issue.record("Expired work must not render an avatar.")
            return nil
        }, fetch: { _, _ in
            await network.wait()
            #expect(Task.isCancelled)
            return .init(catalog: Self.catalog(), messages: [Self.question()])
        }, pause: { duration in
            #expect(duration <= .seconds(3) && duration >= .zero)
            await timerStarted.open()
            await timer.wait()
        })
        var delivered: [UNNotificationContent] = []
        enricher.start(original) { delivered.append($0); Task { await didDeliver.open() } }
        let work = try #require(enricher.work)
        await timerStarted.wait()
        #expect(delivered.isEmpty)
        await timer.open()
        await didDeliver.wait()
        #expect(MobileNotificationEnricher.contentDeadline == .seconds(3))
        #expect(delivered.count == 1)
        #expect(delivered.first === original.content)
        await network.open()
        await work.value
        enricher.expire()
        #expect(delivered.count == 1)
    }

    @Test(arguments: [Duration.milliseconds(2999), .seconds(3)])
    @MainActor func lookupMustFinishBeforeTheThreeSecondBoundary(elapsed: Duration) async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://server.test")
        let original = Self.request(registration: registration)
        let clock = EnrichmentClock(), timer = EnrichmentGate()
        let enricher = MobileNotificationEnricher(directory: directory, avatarPNG: { _ in nil }, fetch: { _, _ in
            await clock.advance(by: elapsed)
            return .init(catalog: Self.catalog(), messages: [Self.question()])
        }, pause: { _ in await timer.wait() }, now: { clock.instant }, donate: { _ in })
        var delivered: UNNotificationContent?
        enricher.start(original) { delivered = $0 }
        let work = try #require(enricher.work)
        await work.value
        await timer.open()
        #expect((delivered === original.content) == (elapsed >= .seconds(3)))
        #expect(delivered?.title == (elapsed < .seconds(3) ? "Studio" : "Toy Box"))
    }

    @Test(arguments: [false, true])
    @MainActor func unreachableOrMissingChannelsDeliverTheOriginal(missing: Bool) async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://server.test")
        let original = Self.request(kind: .completion, registration: registration)
        var reloads = 0
        let enricher = MobileNotificationEnricher(directory: directory, avatarPNG: { _ in nil }, fetch: { _, _ in
            if !missing { throw URLError(.cannotConnectToHost) }
            return .init(catalog: .init(lead: Self.catalog().lead, channels: []))
        }, reloadWidgets: { reloads += 1 })
        var delivered: UNNotificationContent?
        enricher.start(original) { delivered = $0 }
        let work = try #require(enricher.work)
        await work.value
        #expect(delivered === original.content)
        #expect(reloads == 1)
    }

    @Test @MainActor func aDifferentRegistrationClearsOnlyTheCategoryWithoutLookupOrWidgetReload() throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://server.test")
        let other = MobilePushRegistration(serverURL: "https://other.test", registrationID: UUID().uuidString)
        let original = Self.request(registration: other)
        let enricher = MobileNotificationEnricher(directory: directory, avatarPNG: { _ in
            Issue.record("A mismatched notification must not resolve identity.")
            return nil
        }, fetch: { _, _ in
            Issue.record("A mismatched notification must not fetch.")
            throw CancellationError()
        }, reloadWidgets: { Issue.record("A mismatched notification must not reload widgets.") })
        var delivered: UNNotificationContent?
        enricher.start(original) { delivered = $0 }
        let expected = try #require(original.content.mutableCopy() as? UNMutableNotificationContent)
        expected.categoryIdentifier = ""
        #expect(enricher.work == nil)
        #expect(delivered?.isEqual(expected) == true)
        #expect(original.content.categoryIdentifier == "request")
    }

    @Test @MainActor func replacingARequestExpiresTheOriginalAndIgnoresItsLateLookup() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://server.test")
        let first = Self.request(registration: registration)
        let second = Self.request(registration: registration, sequence: 16)
        let network = EnrichmentGate()
        let enricher = MobileNotificationEnricher(directory: directory, avatarPNG: { _ in nil }, fetch: { _, payload in
            if payload.sequence == 15 { await network.wait() }
            return .init(catalog: Self.catalog())
        }, donate: { _ in })
        var delivered: [UNNotificationContent] = []
        enricher.start(first) { delivered.append($0) }
        let firstWork = try #require(enricher.work)
        enricher.start(second) { delivered.append($0) }
        let secondWork = try #require(enricher.work)
        await secondWork.value
        await network.open()
        await firstWork.value
        enricher.expire()
        #expect(delivered.count == 2)
        #expect(delivered.first === first.content)
        #expect(delivered.last?.userInfo["sequence"] as? Int == 16)
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tbm-enrichment-\(UUID())")
    }

    private static func request(kind: ChannelPushPayload.Kind = .request,
                                registration: MobilePushRegistration, sequence: Int = 15) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Toy Box"
        content.body = kind == .request ? NotificationText.waitingBody : NotificationText.completionBody(tasks: [])
        content.sound = .default
        content.categoryIdentifier = kind.rawValue
        content.threadIdentifier = "original-thread"
        content.badge = 4
        content.userInfo = ["kind": kind.rawValue, "channelID": "studio", "sequence": sequence,
                            "registrationID": registration.registrationID, "extra": "untouched"]
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
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

@MainActor private final class EnrichmentClock {
    var instant = ContinuousClock.now
    func advance(by duration: Duration) { instant += duration }
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
