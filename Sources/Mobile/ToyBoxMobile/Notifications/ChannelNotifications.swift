import ToyBoxClient
import ToyBoxKit
import Foundation
import Observation
import OSLog
import TipKit
import ToyBoxMobileIntegrations
import UIKit
import UserNotifications

@MainActor @Observable
final class ChannelNotifications: NSObject, UNUserNotificationCenterDelegate {
    struct Activation: Equatable {
        var channel: ChannelNotification.Activation
        var serverURL: String
    }

    /// A reply typed into a notification, or one of its choices, for the outbox. It goes to the
    /// notification's own server and answers its request.
    struct Reply: Equatable, Sendable {
        var content: String
        var channelID: String
        var server: URL
        var request: Int?
    }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var hasLoadedAuthorization = false
    private(set) var isEnabling = false
    private(set) var tipsAvailable = false
    private(set) var error: String?
    private(set) var registration: MobileNotificationRegistration?
    private(set) var registrationSetupError: String?
    private var enabled: Bool
    var requests: Bool {
        didSet {
            guard requests != oldValue else { return }
            defaults.set(requests, forKey: "requestNotifications")
            updateRegistration()
        }
    }
    var completions: Bool {
        didSet {
            guard completions != oldValue else { return }
            defaults.set(completions, forKey: "completionNotifications")
            updateRegistration()
        }
    }

    @ObservationIgnored var onRegistrationCreated: ((MobilePushRegistration) async -> Void)?
    @ObservationIgnored var onActivate: ((Activation) async -> Void)?
    /// Saves a reply to the outbox, which delivers it to its server now or once that's current again.
    @ObservationIgnored var onReply: ((Reply) async -> Void)?
    private var center: UNUserNotificationCenter { .current() }
    nonisolated private static let logger = Logger(subsystem: "dev.toybox.mobile", category: "Notifications")
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readAuthorization: () async -> UNAuthorizationStatus
    @ObservationIgnored private let requestAuthorization: () async throws -> Bool
    @ObservationIgnored private let openSettings: () async -> Bool
    @ObservationIgnored private let removeDelivered: ([String]) -> Void
    @ObservationIgnored private let setBadgeCount: (Int) async throws -> Void
    @ObservationIgnored private var pendingBadgeCount: Int?
    @ObservationIgnored private var badgeUpdate: Task<Void, Never>?
    @ObservationIgnored private var authorizationGeneration = UUID()
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var installedDelegate = false
    @ObservationIgnored private var enableAfterSettings = false
    private var configuredAPIs: [ChannelAPI] = []
    /// Each server's latest channels, by registration ID.
    @ObservationIgnored private var channels: [String: [Channel]] = [:]
    @ObservationIgnored private var activeChannel: ChannelTarget?
    @ObservationIgnored private let replyCategories = ReplyCategoryPublisher()

    init(defaults: UserDefaults = .standard,
         registration: MobileNotificationRegistration? = nil,
         readAuthorization: @escaping () async -> UNAuthorizationStatus = {
             await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
         },
         requestAuthorization: @escaping () async throws -> Bool = {
             try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
         },
         openSettings: @escaping () async -> Bool = {
             guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }
             return await UIApplication.shared.open(url)
         },
         removeDelivered: @escaping ([String]) -> Void = {
             UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0)
         },
         setBadgeCount: @escaping (Int) async throws -> Void = {
             try await UNUserNotificationCenter.current().setBadgeCount($0)
         }) {
        self.defaults = defaults
        self.registration = registration
        self.readAuthorization = readAuthorization
        self.requestAuthorization = requestAuthorization
        self.openSettings = openSettings
        self.removeDelivered = removeDelivered
        self.setBadgeCount = setBadgeCount
        enabled = defaults.bool(forKey: "notificationsEnabled")
        requests = defaults.object(forKey: "requestNotifications") as? Bool ?? true
        completions = defaults.bool(forKey: "completionNotifications")
        super.init()
    }

    var isAuthorized: Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    var isEnabled: Bool { enabled && isAuthorized }
    var registrationError: String? { registrationSetupError ?? registration?.error }

    /// Each server's registration, in Settings order.
    var registrations: [MobilePushRegistration] {
        let servers = Set(configuredAPIs.map(\.baseURL.absoluteString))
        return registration?.current.filter { servers.contains($0.serverURL) } ?? []
    }

    /// A server's registration, however its address is spelled.
    func registration(for serverURL: String) -> MobilePushRegistration? {
        guard let server = ChannelTarget.normalizedServer(serverURL) else { return nil }
        return registrations.first { ChannelTarget.normalizedServer($0.serverURL) == server }
    }

    func registration(id: String) -> MobilePushRegistration? {
        registrations.first { $0.registrationID == id }
    }

    func isReady(_ registration: MobilePushRegistration?) -> Bool {
        guard let registration, registrations.contains(registration) else { return false }
        return self.registration?.ready.contains(registration.registrationID) == true
    }

    func registrationError(for registration: MobilePushRegistration?) -> String? {
        registrationSetupError ?? self.registration?.tokenError
            ?? registration.flatMap { self.registration?.failures[$0.registrationID] }
    }
    var canOfferPermissionTip: Bool {
        tipsAvailable && hasLoadedAuthorization && authorization == .notDetermined
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        if !enabled { updateBadge(0) }
        do {
            try Tips.configure()
            tipsAvailable = true
        } catch {
            self.error = "Notification tips couldn't be prepared: \(error.localizedDescription)"
        }
        await refreshAuthorization()
    }

    func installDelegate() {
        guard !installedDelegate else { return }
        installedDelegate = true
        center.delegate = self
        Task { await replyCategories.publish() }
        prepareRegistration()
    }

    /// Takes every server, in Settings order.
    func configure(apis: [ChannelAPI]) {
        configuredAPIs = apis
        if installedDelegate { prepareRegistration() }
    }

    private func prepareRegistration() {
        guard !configuredAPIs.isEmpty else { return }
        do {
            if registration == nil {
                guard let value = Bundle.main.object(forInfoDictionaryKey: "ToyBoxPushEnvironment") as? String,
                      let environment = PushEnvironment(rawValue: value) else {
                    throw RegistrationFailure.missingEnvironment
                }
                registration = MobileNotificationRegistration(
                    store: try MobilePushRegistrationStore(), environment: environment,
                    requestToken: { UIApplication.shared.registerForRemoteNotifications() })
            }
            registration?.onCreated = { [weak self] registration in
                guard let self, self.registrations.contains(registration) else { return }
                await self.onRegistrationCreated?(registration)
            }
            let removed = Set(try registration?.select(apis: configuredAPIs).map(\.registrationID) ?? [])
            if !removed.isEmpty { Task { await withdraw(registrations: removed) } }
            registrationSetupError = nil
            updateRegistration()
        } catch {
            registrationSetupError = error.localizedDescription
            Self.logger.error("Could not prepare notification registration: \(error.localizedDescription)")
        }
    }

    func retryRegistration() {
        prepareRegistration()
        if registrationSetupError == nil { registration?.retry() }
    }

    func receivedDeviceToken(_ data: Data) {
        guard !registrations.isEmpty else { return }
        registration?.receivedToken(data)
    }

    func failedToReceiveDeviceToken(_ failure: any Error) {
        registration?.failedToReceiveToken(failure.localizedDescription)
    }

    func refreshAuthorization() async {
        let generation = UUID()
        authorizationGeneration = generation
        let status = await readAuthorization()
        guard generation == authorizationGeneration else { return }
        authorization = status
        hasLoadedAuthorization = true
        if status == .denied { setEnabled(false) }
        if enableAfterSettings, isAuthorized {
            enableAfterSettings = false
            setEnabled(true)
        }
        updateRegistration()
    }

    func enable() async {
        guard !isEnabling else { return }
        isEnabling = true
        error = nil
        defer { isEnabling = false }
        await refreshAuthorization()
        do {
            if authorization == .notDetermined {
                let granted = try await requestAuthorization()
                await refreshAuthorization()
                setEnabled(granted && isAuthorized)
            } else {
                setEnabled(isAuthorized)
            }
        } catch {
            self.error = error.localizedDescription
            await refreshAuthorization()
            setEnabled(false)
        }
    }

    func disable() {
        enableAfterSettings = false
        setEnabled(false)
    }

    func openSystemSettings() async {
        enableAfterSettings = true
        guard await openSettings() else {
            enableAfterSettings = false
            error = "Settings couldn't be opened."
            return
        }
    }

    func clearError() { error = nil }

    func updateBadge(_ count: Int) {
        pendingBadgeCount = enabled ? count : 0
        guard badgeUpdate == nil else { return }
        badgeUpdate = Task { [weak self] in
            guard let self else { return }
            defer { badgeUpdate = nil }
            while let count = pendingBadgeCount {
                pendingBadgeCount = nil
                do {
                    try await setBadgeCount(count)
                } catch {
                    Self.logger.error("Could not update the icon badge: \(error.localizedDescription)")
                }
            }
        }
    }

    private func updateRegistration() {
        guard hasLoadedAuthorization, !registrations.isEmpty else { return }
        registration?.update(enabled: isEnabled, requests: requests, completions: completions)
    }

    private func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if !value { updateBadge(0) }
        defaults.set(value, forKey: "notificationsEnabled")
        updateRegistration()
    }

    /// The channel a push names, on the server its registration belongs to.
    private func target(of payload: ChannelPushPayload) -> ChannelTarget? {
        registration(id: payload.registrationID).flatMap {
            ChannelTarget(serverURL: $0.serverURL, channelID: payload.channelID)
        }
    }

    /// Takes each server's channels by address, and the channel in front, which stays quiet. Servers in
    /// `withdrawing` have refreshed since the app resumed, so their notifications that went stale go.
    func update(channels: [String: [Channel]], activeChannel: ChannelTarget?, withdrawing: Set<String>) async {
        self.channels = Dictionary(channels.compactMap { server, channels in
            registration(for: server).map { ($0.registrationID, channels) }
        }, uniquingKeysWith: { first, _ in first })
        self.activeChannel = activeChannel
        let scopes = withdrawing.compactMap { registration(for: $0)?.registrationID }
        guard !scopes.isEmpty else { return }
        let delivered = await deliveredNotifications()
        let stale = scopes.flatMap { scope -> [String] in
            guard let registration = registration(id: scope), let channels = self.channels[scope] else { return [] }
            let active = self.activeChannel?.serverURL == ChannelTarget.normalizedServer(registration.serverURL)
                ? self.activeChannel?.channelID : nil
            return ChannelNotification.Delivered.stale(delivered, channels: channels, scope: scope, activeChannelID: active)
        }
        if !stale.isEmpty { removeDelivered(stale) }
    }

    /// Clears a removed server's notifications, which nothing can open or answer now.
    private func withdraw(registrations: Set<String>) async {
        let removed = await deliveredNotifications().filter { registrations.contains($0.scope) }
        if !removed.isEmpty { removeDelivered(removed.map(\.identifier)) }
    }

    private func deliveredNotifications() async -> [ChannelNotification.Delivered] {
        await center.deliveredNotifications().compactMap { notification in
            guard let payload = try? ChannelPushPayload(userInfo: notification.request.content.userInfo) else { return nil }
            return ChannelNotification.Delivered(identifier: notification.request.identifier, payload: payload)
        }
    }

    func presentation(for payload: ChannelPushPayload?, category: String,
                      badge: NSNumber? = nil) -> UNNotificationPresentationOptions {
        guard isEnabled else { return [] }
        if payload == nil, category.isEmpty, badge != nil { return [.badge] }
        if let payload, let activeChannel, target(of: payload) == activeChannel { return [] }
        return category == ChannelNotificationCategory.completion ? [.list] : [.banner, .list, .sound]
    }

    /// Handles a notification's action. `server` is the one the notification extension stamped when it
    /// arrived, which a notification from before that, or a test, leaves out.
    func receive(_ payload: ChannelPushPayload, action: String, text: String?, handle: String?,
                 replies: [String]? = nil, server: String? = nil, identifier: String) async {
        if let label = SuggestedReplies(replies).label(forAction: action) {
            // A choice sends its label as written, like the web's answer(label), so no handle is added.
            await sendReply(payload, text: label, handle: nil, server: server, identifier: identifier)
            return
        }
        switch action {
        case ChannelNotificationCategory.reply:
            await sendReply(payload, text: text, handle: handle, server: server, identifier: identifier)
        case UNNotificationDefaultActionIdentifier:
            guard let registration = registration(id: payload.registrationID) else {
                Self.logger.info("Ignored an alert from a removed server's notification registration.")
                return
            }
            await onActivate?(Activation(
                channel: .init(channelID: payload.channelID, kind: payload.kind, sequence: payload.sequence),
                serverURL: registration.serverURL))
        default:
            break
        }
    }

    /// Saves a reply or choice to the outbox before the action returns, then clears its notification,
    /// since the outbox owns it from there and the app keeps it going in the background. A notification
    /// from an earlier registration that doesn't name its server has nowhere to send it.
    private func sendReply(_ payload: ChannelPushPayload, text: String?, handle: String?, server: String?,
                           identifier: String) async {
        guard let reply = ChannelNotification.Reply(text ?? "", to: handle), let onReply else { return }
        let server = server ?? registration(id: payload.registrationID)?.serverURL
        guard let server = server.flatMap(URL.init(string:)) else {
            Self.logger.notice("Dropped a reply to a notification from an earlier server that doesn't name it.")
            return
        }
        await onReply(Reply(content: reply.content, channelID: payload.channelID, server: server,
                            request: payload.kind == .request ? payload.sequence : nil))
        removeDelivered([identifier])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        let payload = try? ChannelPushPayload(userInfo: content.userInfo)
        let category = content.categoryIdentifier
        let badge = content.badge
        Self.completeOnMainActor({
            self.presentation(for: payload, category: category, badge: badge)
        }, completionHandler: completionHandler)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let content = response.notification.request.content
        let payload = Result { try ChannelPushPayload(userInfo: content.userInfo) }
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let handle = content.userInfo["handle"] as? String
        let replies = content.userInfo["replies"] as? [String]
        let server = content.userInfo["serverURL"] as? String
        let identifier = response.notification.request.identifier
        Self.completeOnMainActor({
            do {
                await self.receive(try payload.get(), action: action, text: text, handle: handle,
                                   replies: replies, server: server, identifier: identifier)
            } catch {
                Self.logger.info("Ignored an alert without current channel routing: \(error.localizedDescription)")
            }
        }, completionHandler: { completionHandler() })
    }

    nonisolated static func completeOnMainActor<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> Value,
        completionHandler: @escaping @Sendable (Value) -> Void
    ) {
        Task { @MainActor in
            let value = await operation()
            completionHandler(value)
        }
    }

    private enum RegistrationFailure: LocalizedError {
        case missingEnvironment
        var errorDescription: String? { "This build doesn't declare its notification environment." }
    }
}
