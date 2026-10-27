import ChannelClient
import ChannelKit
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
        var channelID: String
        var sequence: Int?
        var serverURL: String
        var focusComposer: Bool
    }

    struct Delivered: Equatable {
        let identifier: String
        let payload: ChannelPushPayload
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
            preferencesDidChange()
        }
    }
    var completions: Bool {
        didSet {
            guard completions != oldValue else { return }
            defaults.set(completions, forKey: "completionNotifications")
            preferencesDidChange()
        }
    }

    @ObservationIgnored var onPreferencesChange: (() -> Void)?
    @ObservationIgnored var onActivate: ((Activation) async -> Void)?
    @ObservationIgnored var onReply: ((ChannelPushPayload, String, String?) async -> ComposerNotificationReply.Outcome)?
    private var center: UNUserNotificationCenter { .current() }
    nonisolated private static let logger = Logger(subsystem: "dev.toybox.mobile", category: "Notifications")
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readAuthorization: () async -> UNAuthorizationStatus
    @ObservationIgnored private let requestAuthorization: () async throws -> Bool
    @ObservationIgnored private let openSettings: () async -> Bool
    @ObservationIgnored private let addNotice: (UNNotificationRequest) async throws -> Void
    @ObservationIgnored private var authorizationGeneration = UUID()
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var installedDelegate = false
    @ObservationIgnored private var enableAfterSettings = false
    @ObservationIgnored private var configuredAPI: ChannelAPI?
    @ObservationIgnored private var channels: [Channel] = []
    @ObservationIgnored private var activeChannelID: String?

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
         addNotice: @escaping (UNNotificationRequest) async throws -> Void = {
             try await UNUserNotificationCenter.current().add($0)
         }) {
        self.defaults = defaults
        self.registration = registration
        self.readAuthorization = readAuthorization
        self.requestAuthorization = requestAuthorization
        self.openSettings = openSettings
        self.addNotice = addNotice
        enabled = defaults.bool(forKey: "notificationsEnabled")
        requests = defaults.object(forKey: "requestNotifications") as? Bool ?? true
        completions = defaults.object(forKey: "completionNotifications") as? Bool ?? true
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
    var currentRegistration: MobilePushRegistration? {
        guard let current = registration?.current,
              current.serverURL == configuredAPI?.baseURL.absoluteString else { return nil }
        return current
    }
    var canOfferPermissionTip: Bool {
        tipsAvailable && hasLoadedAuthorization && authorization == .notDetermined
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        installDelegate()
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
        let reply = UNTextInputNotificationAction(
            identifier: ChannelNotificationCategory.reply, title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Reply")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ChannelNotificationCategory.request, actions: [reply],
                                   intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: NotificationText.requestPlaceholder),
            UNNotificationCategory(identifier: ChannelNotificationCategory.completion, actions: [],
                                   intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: NotificationText.completionPlaceholder),
            UNNotificationCategory(identifier: ChannelNotificationCategory.replyFailed, actions: [],
                                   intentIdentifiers: []),
        ])
        prepareRegistration()
    }

    func configure(api: ChannelAPI) {
        configuredAPI = api
        if installedDelegate || didStart { prepareRegistration() }
    }

    private func prepareRegistration() {
        guard let configuredAPI else { return }
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
            if try registration?.select(api: configuredAPI) == true {
                center.removeAllDeliveredNotifications()
            }
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
        guard currentRegistration != nil else { return }
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
        preferencesDidChange()
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

    #if DEBUG && targetEnvironment(simulator)
    func scheduleProofNotification(_ kind: ChannelPushPayload.Kind) async throws {
        guard let api = configuredAPI, let registration = currentRegistration else {
            throw ProofFailure.notConfigured
        }
        guard ["localhost", "127.0.0.1", "::1"].contains(api.baseURL.host ?? ""),
              api.baseURL.port == 3210 else { throw ProofFailure.notDemoServer }
        let payload = try Self.proofPayload(kind: kind, catalog: await api.catalog(), registration: registration)
        guard currentRegistration == registration else { throw ProofFailure.registrationChanged }
        let operation = try MobileNotificationEnricher()
        defer { operation.expire() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            operation.start(payload) { content in
                guard self.currentRegistration == registration else {
                    continuation.resume(throwing: ProofFailure.registrationChanged)
                    return
                }
                self.center.add(UNNotificationRequest(
                    identifier: "proof-\(UUID().uuidString)", content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
                )) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }

    static func proofPayload(kind: ChannelPushPayload.Kind, catalog: ChannelCatalog,
                             registration: MobilePushRegistration) throws -> ChannelPushPayload {
        for channel in catalog.channels {
            let sequence = kind == .request ? channel.requestSequence : channel.completedSequence
            if let sequence, sequence > 0 {
                return ChannelPushPayload(kind: kind, channelID: channel.id, sequence: sequence,
                                          registrationID: registration.registrationID)
            }
        }
        throw ProofFailure.noChannel(kind)
    }

    private enum ProofFailure: LocalizedError {
        case notConfigured, notDemoServer, registrationChanged
        case noChannel(ChannelPushPayload.Kind)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Connect to the demo server before preparing an alert."
            case .notDemoServer: "Use the local demo server on port 3210 for proof alerts."
            case .registrationChanged: "The selected server changed while preparing the alert."
            case .noChannel(.request): "The demo has no waiting request."
            case .noChannel(.completion): "The demo has no completed channel."
            }
        }
    }
    #endif

    private func preferencesDidChange() {
        updateRegistration()
        onPreferencesChange?()
    }

    private func updateRegistration() {
        guard hasLoadedAuthorization, currentRegistration != nil else { return }
        registration?.update(enabled: isEnabled, requests: requests, completions: completions)
    }

    private func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        defaults.set(value, forKey: "notificationsEnabled")
        preferencesDidChange()
    }

    func isCurrent(_ payload: ChannelPushPayload) -> Bool {
        currentRegistration?.registrationID == payload.registrationID
    }

    func update(channels: [Channel], activeChannelID: String?, withdraw: Bool) async {
        self.channels = channels
        self.activeChannelID = activeChannelID
        guard withdraw, let registrationID = currentRegistration?.registrationID else { return }
        let delivered = await center.deliveredNotifications().compactMap { notification -> Delivered? in
            guard let payload = try? ChannelPushPayload(userInfo: notification.request.content.userInfo) else { return nil }
            return Delivered(identifier: notification.request.identifier, payload: payload)
        }
        guard currentRegistration?.registrationID == registrationID else { return }
        let stale = Self.stale(delivered, channels: self.channels, registrationID: registrationID,
                               activeChannelID: self.activeChannelID)
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
    }

    static func stale(_ delivered: [Delivered], channels: [Channel], registrationID: String,
                      activeChannelID: String?) -> [String] {
        let byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return delivered.filter { item in
            let payload = item.payload
            guard payload.registrationID == registrationID else { return false }
            if payload.channelID == activeChannelID { return true }
            guard let channel = byID[payload.channelID] else { return payload.kind == .request }
            switch payload.kind {
            case .request: return channel.requestSequence != payload.sequence
            case .completion: return channel.seenThrough >= payload.sequence
            }
        }.map(\.identifier)
    }

    func presentation(for payload: ChannelPushPayload?, category: String) -> UNNotificationPresentationOptions {
        if category == ChannelNotificationCategory.replyFailed { return [.banner, .list, .sound] }
        guard isEnabled else { return [] }
        if let payload, isCurrent(payload), payload.channelID == activeChannelID { return [] }
        return category == ChannelNotificationCategory.completion ? [.list] : [.banner, .list, .sound]
    }

    func receive(_ payload: ChannelPushPayload, action: String, text: String?, handle: String?,
                 identifier: String) async {
        switch action {
        case ChannelNotificationCategory.reply:
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard isCurrent(payload), let onReply else {
                await replyWasNotSent()
                return
            }
            switch await onReply(payload, text, handle) {
            case .sent:
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
            case .failed:
                break
            case .notSent:
                await replyWasNotSent()
            }
        case UNNotificationDefaultActionIdentifier:
            guard isCurrent(payload), let currentRegistration else {
                Self.logger.info("Ignored an alert from a previous notification registration.")
                return
            }
            await onActivate?(Activation(
                channelID: payload.channelID, sequence: payload.kind == .request ? payload.sequence : nil,
                serverURL: currentRegistration.serverURL, focusComposer: false))
        default:
            break
        }
    }

    private func replyWasNotSent() async {
        let content = UNMutableNotificationContent()
        content.title = "Toy Box"
        content.body = "Your reply wasn't sent."
        content.categoryIdentifier = ChannelNotificationCategory.replyFailed
        content.sound = .default
        do {
            try await addNotice(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            self.error = error.localizedDescription
            Self.logger.error("Could not show the unsent reply notice: \(error.localizedDescription)")
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        let payload = try? ChannelPushPayload(userInfo: content.userInfo)
        return await presentation(for: payload, category: content.categoryIdentifier)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        do {
            let payload = try ChannelPushPayload(userInfo: content.userInfo)
            await receive(payload, action: response.actionIdentifier,
                          text: (response as? UNTextInputNotificationResponse)?.userText,
                          handle: content.userInfo["handle"] as? String,
                          identifier: response.notification.request.identifier)
        } catch {
            Self.logger.info("Ignored an alert without current channel routing: \(error.localizedDescription)")
        }
    }

    private enum RegistrationFailure: LocalizedError {
        case missingEnvironment
        var errorDescription: String? { "This build doesn't declare its notification environment." }
    }
}
