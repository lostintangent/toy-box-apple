import AppKit
import ChannelClient
import ChannelKit
import Observation
import UserNotifications

@MainActor @Observable
final class ChannelNotifications: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let replyAction = ChannelNotificationCategory.reply
    /// How long a request waits for its text before it's delivered without it.
    static let contentDeadline: Duration = .seconds(3)

    struct Activation: Equatable {
        var channel: ChannelNotification.Activation
        var serverURL: String
    }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var error: String?
    @ObservationIgnored var onActivate: ((Activation) -> Void)?
    /// Finds a request's message, from an open channel's state or else its history.
    @ObservationIgnored var resolveRequest: ((Channel, Int) async -> ChannelRequestMessage?)?
    /// Saves a reply to the outbox, which delivers it to its server now or once that's current again.
    @ObservationIgnored var send: ((NotificationReply) async -> Void)?
    @ObservationIgnored private var policy = Policy()
    @ObservationIgnored private var current: Current?
    @ObservationIgnored private var withdrawn: Current?
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private let replyCategories = ReplyCategoryPublisher(base: ChannelNotifications.baseCategories())

    /// What the catalog last said, which decides what's delivered and what's withdrawn.
    private struct Current {
        var channels: [Channel]
        var activeChannelID: String?
        var serverURL: String

        /// Only these change what withdrawal removes, so a poll that changes nothing else doesn't
        /// ask Notification Center for its delivered notifications again.
        func withdrawsLike(_ other: Current?) -> Bool {
            guard let other, serverURL == other.serverURL, activeChannelID == other.activeChannelID,
                  channels.count == other.channels.count else { return false }
            return zip(channels, other.channels).allSatisfy {
                $0.id == $1.id && $0.requestSequence == $1.requestSequence && $0.seenThrough == $1.seenThrough
            }
        }
    }

    override init() {
        super.init()
        center.delegate = self
        Task { await replyCategories.publish() }
    }

    /// The shared reply categories plus the morning digest, which only the Mac posts.
    static func baseCategories() -> Set<UNNotificationCategory> {
        ReplyCategories.baseCategories().union([
            UNNotificationCategory(identifier: MorningDigest.category, actions: [], intentIdentifiers: []),
        ])
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    func enable() async -> Bool {
        error = nil
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            return granted
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func reset() {
        policy = Policy()
    }

    func update(channels: [Channel], activeChannelID: String?, serverURL: String) {
        current = Current(channels: channels, activeChannelID: activeChannelID, serverURL: serverURL)
        let events = policy.events(
            channels: channels, activeChannelID: activeChannelID,
            enabled: UserDefaults.standard.bool(forKey: "notificationsEnabled"),
            requests: UserDefaults.standard.object(forKey: "requestNotifications") as? Bool != false,
            completions: UserDefaults.standard.bool(forKey: "completionNotifications")
        )
        for event in events {
            deliver(event, serverURL: serverURL)
        }
        withdrawStale()
    }

    private func deliver(_ event: Event, serverURL: String) {
        Task {
            let request = event.kind == .request ? await resolve(event) : nil
            if let labels = request?.message.suggestedReplies, !labels.isEmpty {
                await replyCategories.publish(adding: ReplyCategories.category(labels: labels))
            }
            await add(UNNotificationRequest(
                identifier: "\(serverURL):\(event.channel.id):\(event.kind.rawValue):\(event.sequence)",
                content: Self.content(for: event, serverURL: serverURL, request: request), trigger: nil))
            // A request answered while its text was on the way is withdrawn as soon as it lands.
            withdrawStale(force: true)
        }
    }

    static func content(for event: Event, serverURL: String,
                        request: ChannelRequestMessage? = nil) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = event.channel.name
        content.sound = .default
        content.categoryIdentifier = event.kind.rawValue
        content.threadIdentifier = "\(serverURL):\(event.channel.id)"
        var info: [String: Any] = ["channelID": event.channel.id, "channelName": event.channel.name,
                                   "sequence": event.sequence, "kind": event.kind.rawValue, "serverURL": serverURL]
        switch event.kind {
        case .request:
            if let request {
                content.body = ChannelNotification.Content(request: request).body
                if let requester = request.requester {
                    info["handle"] = requester.handle
                }
                let labels = request.message.suggestedReplies
                if !labels.isEmpty {
                    content.categoryIdentifier = ReplyCategories.identifier(labels: labels)
                    info["replies"] = labels
                }
            } else {
                content.body = ChannelNotification.Content.waitingBody
            }
        case .completion:
            content.body = ChannelNotification.Content(completion: event.channel.tasks).body
        }
        content.userInfo = info
        return content
    }

    /// Never waits longer than the deadline, and never delivers twice when the text arrives late.
    private func resolve(_ event: Event) async -> ChannelRequestMessage? {
        guard let resolveRequest else { return nil }
        let work = Task { await resolveRequest(event.channel, event.sequence) }
        let deadline = Task {
            try? await Task.sleep(for: Self.contentDeadline, tolerance: .zero)
            work.cancel()
        }
        defer { deadline.cancel() }
        return await work.value
    }

    private func add(_ request: UNNotificationRequest) async {
        do { try await center.add(request) }
        catch { self.error = error.localizedDescription }
    }

    func deliverMorningDigest(_ digest: MorningDigest.Content, serverURL: String, identifier: String) async throws {
        guard let content = Self.morningDigestContent(digest, serverURL: serverURL) else { return }
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    static func morningDigestContent(_ digest: MorningDigest.Content, serverURL: String) -> UNNotificationContent? {
        guard let busiest = digest.busiest else { return nil }
        let content = UNMutableNotificationContent()
        content.title = "Morning digest"
        content.body = digest.body
        content.categoryIdentifier = MorningDigest.category
        content.threadIdentifier = MorningDigest.category
        content.userInfo = ["channelID": busiest.channelID, "channelName": busiest.name,
                            "kind": MorningDigest.category, "serverURL": serverURL]
        return content
    }

    private func withdrawStale(force: Bool = false) {
        guard let current, force || !current.withdrawsLike(withdrawn) else { return }
        withdrawn = current
        Task {
            let delivered = await center.deliveredNotifications().compactMap {
                Self.delivered(identifier: $0.request.identifier, userInfo: $0.request.content.userInfo)
            }
            guard let current = self.current else { return }
            let stale = ChannelNotification.Delivered.stale(delivered, channels: current.channels,
                                                  scope: current.serverURL,
                                                  activeChannelID: current.activeChannelID)
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    /// Digests are never withdrawn, so they never reach the stale check.
    nonisolated static func delivered(identifier: String, userInfo: [AnyHashable: Any]) -> ChannelNotification.Delivered? {
        guard let server = userInfo["serverURL"] as? String, let channelID = userInfo["channelID"] as? String,
              let kind = userInfo["kind"] as? String, kind != MorningDigest.category else { return nil }
        return .init(identifier: identifier, scope: server, channelID: channelID,
                     kind: ChannelPushPayload.Kind(rawValue: kind), sequence: userInfo["sequence"] as? Int ?? 0)
    }

    /// Saves a reply or choice without bringing the app forward, then clears its notification, since
    /// the outbox owns it from there.
    private func save(_ reply: NotificationReply, from identifier: String) async {
        guard let send else { return }
        await send(reply)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func presentation(kind: String?, channelID: String?, serverURL: String?) -> UNNotificationPresentationOptions {
        let isActive = current.map { $0.serverURL == serverURL && $0.activeChannelID != nil
            && $0.activeChannelID == channelID } ?? false
        return NotificationPresentation.options(kind: kind, isActiveChannel: isActive)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        let kind = info["kind"] as? String
        let channelID = info["channelID"] as? String
        let server = info["serverURL"] as? String
        return await presentation(kind: kind, channelID: channelID, serverURL: server)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["channelID"] as? String, let server = info["serverURL"] as? String else { return }
        let kind = info["kind"] as? String
        let sequence = info["sequence"] as? Int
        if let reply = NotificationReply(action: response.actionIdentifier,
                                         text: (response as? UNTextInputNotificationResponse)?.userText, info: info) {
            await save(reply, from: response.notification.request.identifier)
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let activation = Activation(
                channel: .init(channelID: id, kind: kind.flatMap(ChannelPushPayload.Kind.init(rawValue:)),
                               sequence: sequence),
                serverURL: server)
            await MainActor.run { onActivate?(activation) }
        }
    }

    struct Event: Equatable {
        typealias Kind = ChannelPushPayload.Kind
        let channel: Channel
        let sequence: Int
        let kind: Kind
    }

    struct Policy {
        private var milestones: [String: (request: Int?, completion: Int?)] = [:]
        private var hasBaseline = false

        mutating func events(channels: [Channel], activeChannelID: String?, enabled: Bool,
                             requests: Bool = true, completions: Bool = false) -> [Event] {
            let shouldNotify = hasBaseline
            hasBaseline = true
            var result: [Event] = []
            for channel in channels {
                let old = milestones[channel.id]
                milestones[channel.id] = (channel.requestSequence, channel.completedSequence)
                guard shouldNotify, enabled, channel.id != activeChannelID else { continue }
                if let sequence = channel.requestSequence, old?.request != sequence, requests {
                    result.append(Event(channel: channel, sequence: sequence, kind: .request))
                } else if let sequence = channel.completedSequence, sequence > channel.seenThrough,
                          old?.completion != sequence, completions {
                    result.append(Event(channel: channel, sequence: sequence, kind: .completion))
                }
            }
            return result
        }
    }
}
