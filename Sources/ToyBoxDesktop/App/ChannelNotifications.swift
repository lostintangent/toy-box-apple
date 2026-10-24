import AppKit
import ChannelClient
import ChannelKit
import Observation
import UserNotifications

@MainActor @Observable
final class ChannelNotifications: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let replyAction = "reply"
    nonisolated static let replyFailedCategory = "replyFailed"
    /// How long a request waits for its text before it's delivered without it.
    static let contentDeadline: Duration = .seconds(3)

    struct Activation: Equatable {
        var channelID: String
        var sequence: Int?
        var serverURL: String
        var focusComposer = false
    }

    /// A request's message and the agents its mentions can name.
    struct ResolvedRequest {
        var message: ChannelMessage
        var agents: [ChannelAgent]
    }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var error: String?
    @ObservationIgnored var onActivate: ((Activation) -> Void)?
    /// Finds a request's message, from an open channel's state or else its history.
    @ObservationIgnored var resolveRequest: ((Channel, Int) async -> ResolvedRequest?)?
    /// The API for a server, only while it's the current one.
    @ObservationIgnored var api: ((String) -> ChannelAPI?)?
    @ObservationIgnored private var policy = Policy()
    @ObservationIgnored private var current: Current?
    @ObservationIgnored private var withdrawn: Current?
    @ObservationIgnored private let center = UNUserNotificationCenter.current()

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
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Reply")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Event.Kind.request.rawValue, actions: [reply], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: NotificationText.requestPlaceholder),
            UNNotificationCategory(identifier: Event.Kind.completion.rawValue, actions: [], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: NotificationText.completionPlaceholder),
            UNNotificationCategory(identifier: Self.replyFailedCategory, actions: [], intentIdentifiers: []),
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
            completions: UserDefaults.standard.object(forKey: "completionNotifications") as? Bool != false
        )
        for event in events {
            deliver(event, serverURL: serverURL)
        }
        withdrawStale()
    }

    private func deliver(_ event: Event, serverURL: String) {
        Task {
            await add(UNNotificationRequest(
                identifier: "\(serverURL):\(event.channel.id):\(event.kind.rawValue):\(event.sequence)",
                content: await content(for: event, serverURL: serverURL), trigger: nil))
            // A request answered while its text was on the way is withdrawn as soon as it lands.
            withdrawStale(force: true)
        }
    }

    func content(for event: Event, serverURL: String) async -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = event.channel.name
        content.sound = .default
        content.categoryIdentifier = event.kind.rawValue
        content.threadIdentifier = "\(serverURL):\(event.channel.id)"
        var info: [String: Any] = ["channelID": event.channel.id, "channelName": event.channel.name,
                                   "sequence": event.sequence, "kind": event.kind.rawValue, "serverURL": serverURL]
        switch event.kind {
        case .request:
            if let request = await resolve(event) {
                content.body = NotificationText.requestBody(request.message, agents: request.agents)
                if let requester = request.agents.first(where: { $0.id == request.message.sender.agentId }) {
                    content.subtitle = NotificationText.subtitle(requester: requester.name)
                    info["handle"] = agentHandleFromName(requester.name)
                }
            } else {
                content.body = NotificationText.waitingBody
            }
        case .completion:
            content.body = NotificationText.completionBody(tasks: event.channel.tasks)
        }
        content.userInfo = info
        return content
    }

    /// Never waits longer than the deadline, and never delivers twice when the text arrives late.
    private func resolve(_ event: Event) async -> ResolvedRequest? {
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
            let delivered = await center.deliveredNotifications().compactMap(Self.delivered)
            guard let current = self.current else { return }
            let stale = NotificationWithdrawal.stale(delivered, channels: current.channels,
                                                     serverURL: current.serverURL,
                                                     activeChannelID: current.activeChannelID)
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    private nonisolated static func delivered(_ notification: UNNotification) -> NotificationWithdrawal.Delivered? {
        let request = notification.request
        let info = request.content.userInfo
        guard let server = info["serverURL"] as? String, let channelID = info["channelID"] as? String,
              let kind = info["kind"] as? String else { return nil }
        return .init(identifier: request.identifier, serverURL: server, channelID: channelID, kind: kind,
                     sequence: info["sequence"] as? Int ?? 0)
    }

    /// Posts a reply typed into a notification without bringing the app forward. A reply that
    /// can't be sent is never lost: it becomes the channel's draft on its own server.
    func reply(_ text: String, channelID: String, channelName: String, handle: String?, serverURL: String) async {
        guard let content = NotificationText.addressedReply(text, to: handle) else { return }
        var outcome = NotificationReply.Outcome.failed
        if let api = api?(serverURL) {
            outcome = await NotificationReply(
                post: { id, content in try await api.post(channelId: channelID, id: id, content: content) },
                markRead: { sequence in _ = try await api.markRead(channelId: channelID, sequence: sequence) }
            ).send(content)
        }
        guard outcome != .sent, let server = URL(string: serverURL) else { return }
        let draft = ComposerDraft.shared(serverURL: server, channelID: channelID)
        draft.text = NotificationText.draft(draft.text, adding: content)

        let notice = UNMutableNotificationContent()
        notice.title = channelName
        notice.body = outcome == .deleted ? NotificationText.deletedBody(channel: channelName) : NotificationText.unsentBody
        notice.sound = .default
        notice.categoryIdentifier = Self.replyFailedCategory
        notice.threadIdentifier = "\(serverURL):\(channelID)"
        notice.userInfo = ["channelID": channelID, "channelName": channelName,
                           "kind": Self.replyFailedCategory, "serverURL": serverURL]
        await add(UNNotificationRequest(identifier: "\(serverURL):\(channelID):\(Self.replyFailedCategory):\(UUID().uuidString)",
                                        content: notice, trigger: nil))
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
        let content = response.notification.request.content
        let info = content.userInfo
        guard let id = info["channelID"] as? String, let server = info["serverURL"] as? String else { return }
        let kind = info["kind"] as? String
        let sequence = info["sequence"] as? Int
        let name = info["channelName"] as? String ?? content.title
        let handle = info["handle"] as? String
        switch response.actionIdentifier {
        case Self.replyAction:
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            await reply(text, channelID: id, channelName: name, handle: handle, serverURL: server)
        case UNNotificationDefaultActionIdentifier:
            let activation = Activation(channelID: id, sequence: kind == Event.Kind.request.rawValue ? sequence : nil,
                                        serverURL: server, focusComposer: kind == Self.replyFailedCategory)
            await MainActor.run { onActivate?(activation) }
        default:
            break
        }
    }

    struct Event: Equatable {
        enum Kind: String { case request, completion }
        let channel: Channel
        let sequence: Int
        let kind: Kind
    }

    struct Policy {
        private var milestones: [String: (request: Int?, completion: Int?)] = [:]
        private var hasBaseline = false

        mutating func events(channels: [Channel], activeChannelID: String?, enabled: Bool,
                             requests: Bool = true, completions: Bool = true) -> [Event] {
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
