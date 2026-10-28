import ChannelClient
import ChannelKit
import Foundation
import Intents
import OSLog
import SwiftUI
import ToyBoxUI
import UIKit
import UserNotifications
import WidgetKit

@MainActor
public enum MobileNotificationAvatar {
    public static func png(_ agent: ChannelAgent) -> Data? {
        let renderer = ImageRenderer(content: AgentAvatarView(agent: agent, size: 128))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return UIImage(cgImage: image).pngData()
    }
}

@MainActor
public final class MobileNotificationEnricher {
    public static let contentDeadline: Duration = .seconds(3)

    struct Fetched: Sendable {
        var catalog: ChannelCatalog
        var messages: [ChannelMessage] = []
    }

    typealias Fetch = @Sendable (ChannelAPI, ChannelPushPayload) async throws -> Fetched
    private let directory: URL
    private let avatarPNG: @MainActor (ChannelAgent) -> Data?
    private let fetch: Fetch
    private let pause: @Sendable (Duration) async throws -> Void
    private let now: @MainActor () -> ContinuousClock.Instant
    private let donate: @MainActor (INSendMessageIntent) -> Void
    private let reloadWidgets: @MainActor () -> Void
    private let logger = Logger(subsystem: "dev.toybox.mobile", category: "Notification")
    private var completion: (@MainActor (UNNotificationContent?) -> Void)?
    private(set) var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    public convenience init(directory: URL? = nil,
                            avatarPNG: @escaping @MainActor (ChannelAgent) -> Data? = MobileNotificationAvatar.png) throws {
        try self.init(directory: directory ?? MobileSharedContainer.url(), avatarPNG: avatarPNG, fetch: Self.fetch,
                      reloadWidgets: { WidgetCenter.shared.reloadTimelines(ofKind: NeedsYouSnapshot.kind) })
    }

    init(directory: URL, avatarPNG: @escaping @MainActor (ChannelAgent) -> Data?,
         fetch: @escaping Fetch, reloadWidgets: @escaping @MainActor () -> Void = {},
         pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         donate: @escaping @MainActor (INSendMessageIntent) -> Void = MobileNotificationEnricher.donate) {
        self.directory = directory
        self.avatarPNG = avatarPNG
        self.fetch = fetch
        self.pause = pause
        self.now = now
        self.donate = donate
        self.reloadWidgets = reloadWidgets
    }

    public func start(_ request: UNNotificationRequest,
                      completion: @escaping @MainActor (UNNotificationContent) -> Void) {
        expire()
        let started = now()
        self.completion = { completion($0 ?? request.content) }
        let payload: ChannelPushPayload
        let registration: MobilePushRegistration
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            logger.error("Could not copy notification content for enrichment.")
            finish()
            return
        }
        do {
            payload = try ChannelPushPayload(userInfo: request.content.userInfo)
            guard let selected = try MobilePushRegistrationStore(directory: directory).current,
                  selected.registrationID == payload.registrationID else {
                logger.notice("Ignoring notification routing for a different registration.")
                content.categoryIdentifier = ""
                finish(content)
                return
            }
            registration = selected
        } catch {
            logger.error("Could not read notification routing: \(error.localizedDescription)")
            finish()
            return
        }
        reloadWidgets()
        let fetch = fetch
        work = Task {
            do {
                let result = try await fetch(ChannelAPI(serverURL: registration.serverURL), payload)
                try Task.checkCancellation()
                let resolved = started.duration(to: self.now()) < Self.contentDeadline
                    ? result.catalog.channels.first(where: { $0.id == payload.channelID }).map {
                        self.content(content, payload: payload, registration: registration,
                                     channel: $0, fetched: result)
                    } : nil
                self.finish(started.duration(to: self.now()) < Self.contentDeadline ? resolved : nil)
            } catch {
                if !Task.isCancelled {
                    self.logger.error("Could not enrich a notification: \(error.localizedDescription)")
                    self.finish()
                }
            }
        }
        let pause = pause
        deadline = Task {
            do {
                try await pause(max(.zero, Self.contentDeadline - started.duration(to: self.now())))
                try Task.checkCancellation()
                self.logger.notice("Notification enrichment reached its three-second deadline.")
                self.finish()
            } catch {
                if !Task.isCancelled {
                    self.logger.error("Notification deadline failed: \(error.localizedDescription)")
                    self.finish()
                }
            }
        }
    }

    public func expire() { finish() }

    private func finish(_ content: UNNotificationContent? = nil) {
        guard let completion else { return }
        self.completion = nil
        work?.cancel()
        deadline?.cancel()
        work = nil
        deadline = nil
        completion(content)
    }

    private func content(_ content: UNMutableNotificationContent, payload: ChannelPushPayload,
                         registration: MobilePushRegistration, channel: Channel, fetched: Fetched) -> UNNotificationContent {
        content.title = channel.name
        content.threadIdentifier = "\(registration.serverURL):\(payload.channelID)"
        switch payload.kind {
        case .completion:
            content.body = NotificationText.completionBody(tasks: channel.tasks)
            return content
        case .request:
            let lead = ChannelAgent.lead(id: channel.id, profile: fetched.catalog.lead)
            let agents = [lead] + fetched.catalog.members.filter { $0.channelId == channel.id }
            let request = fetched.messages.first { $0.sequence == payload.sequence }
                .map { ChannelRequestMessage(message: $0, agents: agents) }
            if let request { content.body = NotificationText.requestBody(request.message, agents: request.agents) }
            let sender = request?.requester ?? lead
            if let requester = request?.requester {
                content.userInfo["handle"] = agentHandleFromName(requester.name)
            }
            content.subtitle = NotificationText.subtitle(requester: sender.name)
            let png = avatarPNG(sender)
            if png == nil { logger.error("Could not render a notification avatar.") }
            let image = png.map(INImage.init(imageData:))
            let person = INPerson(personHandle: .init(value: sender.id, type: .unknown), nameComponents: nil,
                                  displayName: sender.name, image: image,
                                  contactIdentifier: nil, customIdentifier: sender.id)
            let recipient = INPerson(
                personHandle: .init(value: "user", type: .unknown), nameComponents: nil,
                displayName: nil, image: nil, contactIdentifier: nil, customIdentifier: "user",
                isMe: true, suggestionType: .none)
            let intent = INSendMessageIntent(
                recipients: [recipient], outgoingMessageType: .outgoingMessageText, content: content.body,
                speakableGroupName: .init(spokenPhrase: channel.name),
                conversationIdentifier: content.threadIdentifier, serviceName: nil, sender: person, attachments: nil
            )
            let metadata = INSendMessageIntentDonationMetadata()
            metadata.recipientCount = agents.count
            intent.donationMetadata = metadata
            // Named group banners use the group's image rather than the INPerson image.
            if let image { intent.setImage(image, forParameterNamed: \.speakableGroupName) }
            donate(intent)
            do { return try content.updating(from: intent) }
            catch { logger.error("Could not apply notification identity: \(error.localizedDescription)") }
            return content
        }
    }

    private static func donate(_ intent: INSendMessageIntent) {
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { error in
            if let error {
                Logger(subsystem: "dev.toybox.mobile", category: "Notification")
                    .error("Could not donate notification identity: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func fetch(api: ChannelAPI, payload: ChannelPushPayload) async throws -> Fetched {
        async let catalog = api.catalog()
        if payload.kind == .request {
            async let history = api.history(channelId: payload.channelID, before: payload.sequence + 1)
            return try await Fetched(catalog: catalog, messages: history.messages)
        }
        return try await Fetched(catalog: catalog)
    }
}
