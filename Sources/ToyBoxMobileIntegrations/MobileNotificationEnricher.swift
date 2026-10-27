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

struct MobileNotificationCatalogCache: Codable, Equatable {
    static let fileName = "notification-catalog.json"
    var registration: MobilePushRegistration
    var catalog: ChannelCatalog

    func write(directory: URL) throws {
        let file = directory.appendingPathComponent(Self.fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func read(directory: URL) throws -> Self {
        let file = directory.appendingPathComponent(fileName)
        let cache = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard cache.catalog.version == 1 else { throw ChannelAPIError.unsupportedVersion(cache.catalog.version) }
        return cache
    }
}

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
    private let reloadWidgets: @MainActor () -> Void
    private let logger = Logger(subsystem: "dev.toybox.mobile", category: "Notification")
    private var completion: (@MainActor (UNNotificationContent) -> Void)?
    private(set) var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var registration: MobilePushRegistration?
    private var fallback: UNNotificationContent = UNMutableNotificationContent()
    private(set) var pendingIntent: INSendMessageIntent?

    public convenience init(directory: URL? = nil,
                            avatarPNG: @escaping @MainActor (ChannelAgent) -> Data? = MobileNotificationAvatar.png) throws {
        try self.init(directory: directory ?? MobileSharedContainer.url(), avatarPNG: avatarPNG, fetch: Self.fetch,
                      reloadWidgets: { WidgetCenter.shared.reloadTimelines(ofKind: NeedsYouSnapshot.kind) })
    }

    init(directory: URL, avatarPNG: @escaping @MainActor (ChannelAgent) -> Data?,
         fetch: @escaping Fetch,
         reloadWidgets: @escaping @MainActor () -> Void = {},
         pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.directory = directory
        self.avatarPNG = avatarPNG
        self.fetch = fetch
        self.pause = pause
        self.reloadWidgets = reloadWidgets
    }

    public func start(_ payload: ChannelPushPayload,
                      completion: @escaping @MainActor (UNNotificationContent) -> Void) {
        expire()
        let started = ContinuousClock.now
        self.completion = completion
        fallback = Self.generic()
        pendingIntent = nil
        registration = nil
        do {
            guard let selected = try MobilePushRegistrationStore(directory: directory).current,
                  selected.registrationID == payload.registrationID else {
                logger.notice("Ignoring notification routing for a different registration.")
                finish(fallback)
                return
            }
            registration = selected
        } catch {
            logger.error("Could not read notification routing: \(error.localizedDescription)")
            finish(fallback)
            return
        }
        guard let registration else { finish(fallback); return }
        var cached: ChannelCatalog?
        do {
            let cache = try MobileNotificationCatalogCache.read(directory: directory)
            if Self.matches(cache.registration, registration) { cached = cache.catalog }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        } catch {
            logger.error("Could not read cached notification identity: \(error.localizedDescription)")
        }
        fallback = content(payload: payload, registration: registration, catalog: cached)
        guard started.duration(to: .now) < Self.contentDeadline else { finish(fallback); return }
        let fetch = fetch
        work = Task {
            do {
                let result = try await fetch(ChannelAPI(serverURL: registration.serverURL), payload)
                try Task.checkCancellation()
                guard started.duration(to: .now) < Self.contentDeadline else {
                    self.finish(self.fallback)
                    return
                }
                guard self.isCurrent() else { self.finish(Self.generic()); return }
                do {
                    try MobileNotificationCatalogCache(registration: registration, catalog: result.catalog)
                        .write(directory: self.directory)
                } catch {
                    self.logger.error("Could not cache notification identity: \(error.localizedDescription)")
                }
                guard result.catalog.channels.contains(where: { $0.id == payload.channelID }) else {
                    self.logger.notice("The notification channel is no longer available.")
                    self.finish(Self.generic())
                    return
                }
                let resolved = self.content(payload: payload, registration: registration,
                                            catalog: result.catalog, messages: result.messages, enriched: true)
                self.finish(resolved)
            } catch {
                if !Task.isCancelled {
                    self.logger.error("Could not enrich a notification: \(error.localizedDescription)")
                    self.finish(self.fallback)
                }
            }
        }
        let pause = pause
        deadline = Task {
            do {
                try await pause(max(.zero, Self.contentDeadline - started.duration(to: .now)))
                try Task.checkCancellation()
                self.logger.notice("Notification enrichment reached its three-second deadline.")
                self.finish(self.fallback)
            } catch {
                if !Task.isCancelled {
                    self.logger.error("Notification deadline failed: \(error.localizedDescription)")
                    self.finish(self.fallback)
                }
            }
        }
    }

    public func expire() {
        if completion != nil { finish(fallback) }
    }

    public static func generic() -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Toy Box"
        content.body = "Open Toy Box to see your team."
        content.sound = .default
        return content
    }

    private func finish(_ content: UNNotificationContent) {
        guard let completion else { return }
        self.completion = nil
        work?.cancel()
        deadline?.cancel()
        work = nil
        deadline = nil
        var result = registration == nil || isCurrent() ? content : Self.generic()
        if result.categoryIdentifier == ChannelNotificationCategory.request, let pendingIntent {
            let interaction = INInteraction(intent: pendingIntent, response: nil)
            interaction.direction = .incoming
            interaction.donate { error in
                if let error {
                    Logger(subsystem: "dev.toybox.mobile", category: "Notification")
                        .error("Could not donate notification identity: \(error.localizedDescription)")
                }
            }
            do { result = try result.updating(from: pendingIntent) }
            catch { logger.error("Could not apply notification identity: \(error.localizedDescription)") }
        }
        if result.categoryIdentifier == ChannelNotificationCategory.request
            || result.categoryIdentifier == ChannelNotificationCategory.completion {
            reloadWidgets()
        }
        completion(result)
    }

    private func isCurrent() -> Bool {
        do {
            guard let registration, let current = try MobilePushRegistrationStore(directory: directory).current else {
                return false
            }
            return Self.matches(registration, current)
        } catch {
            logger.error("Could not recheck notification registration: \(error.localizedDescription)")
            return false
        }
    }

    private static func matches(_ first: MobilePushRegistration, _ second: MobilePushRegistration) -> Bool {
        first.registrationID == second.registrationID
            && ChannelWaitingRequest.normalizedServer(first.serverURL)
                == ChannelWaitingRequest.normalizedServer(second.serverURL)
    }

    private func content(payload: ChannelPushPayload, registration: MobilePushRegistration,
                         catalog: ChannelCatalog?, messages: [ChannelMessage] = [],
                         enriched: Bool = false) -> UNNotificationContent {
        pendingIntent = nil
        let content = UNMutableNotificationContent()
        let channel = catalog?.channels.first { $0.id == payload.channelID }
        content.title = channel?.name ?? "Toy Box"
        content.categoryIdentifier = payload.kind.rawValue
        content.threadIdentifier = "\(registration.serverURL):\(payload.channelID)"
        content.userInfo = payload.userInfo
        content.sound = .default
        switch payload.kind {
        case .completion:
            content.body = NotificationText.completionBody(tasks: enriched ? channel?.tasks ?? [] : [])
            return content
        case .request:
            content.body = NotificationText.waitingBody
            guard let catalog, let channel else { return content }
            let lead = ChannelAgent.lead(id: channel.id, profile: catalog.lead)
            let agents = [lead] + catalog.members.filter { $0.channelId == channel.id }
            let request = messages.first { $0.sequence == payload.sequence }
                .map { ChannelRequestMessage(message: $0, agents: agents) }
            if let request { content.body = NotificationText.requestBody(request.message, agents: request.agents) }
            let sender = request?.requester ?? lead
            if let requester = request?.requester {
                var info = payload.userInfo
                info["handle"] = agentHandleFromName(requester.name)
                content.userInfo = info
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
            pendingIntent = intent
            return content
        }
    }

    nonisolated private static func fetch(api: ChannelAPI, payload: ChannelPushPayload) async throws -> Fetched {
        async let catalog = api.catalog()
        if payload.kind == .request {
            guard payload.sequence < Int.max else { throw ChannelAPIError.invalidMessage("Invalid request sequence.") }
            async let history = api.history(channelId: payload.channelID, before: payload.sequence + 1)
            return try await Fetched(catalog: catalog, messages: history.messages)
        }
        return try await Fetched(catalog: catalog)
    }
}
