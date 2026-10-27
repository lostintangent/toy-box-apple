import ChannelClient
import ChannelKit
import Foundation
import Observation
import OSLog
import ToyBoxMobileIntegrations

@MainActor @Observable
final class MobileNotificationRegistration {
    private(set) var current: MobilePushRegistration?
    private(set) var error: String?
    @ObservationIgnored var onCreated: ((MobilePushRegistration) async -> Void)?

    private struct Preferences: Equatable {
        var enabled: Bool
        var requests: Bool
        var completions: Bool
    }

    private struct Operation: Equatable {
        let api: ChannelAPI
        let registrationID: String
        let input: PushRegistration?
        let topics: [String]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.api.baseURL == rhs.api.baseURL && lhs.registrationID == rhs.registrationID
                && lhs.input == rhs.input && lhs.topics == rhs.topics
        }
    }

    @ObservationIgnored private let store: MobilePushRegistrationStore
    @ObservationIgnored private let environment: PushEnvironment
    @ObservationIgnored private let register: (ChannelAPI, PushRegistration) async throws -> Bool
    @ObservationIgnored private let remove: (ChannelAPI, String) async throws -> Void
    @ObservationIgnored private let subscribe: (ChannelAPI, String, String) async throws -> Void
    @ObservationIgnored private let unsubscribe: (ChannelAPI, String, String) async throws -> Void
    @ObservationIgnored private let requestToken: () -> Void
    @ObservationIgnored private let logger = Logger(subsystem: "dev.toybox.mobile", category: "PushRegistration")
    @ObservationIgnored private var api: ChannelAPI?
    @ObservationIgnored private var preferences: Preferences?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var requestedToken = false
    @ObservationIgnored private var desired: Operation?
    @ObservationIgnored private var attempted: Operation?
    @ObservationIgnored private var removals: [Operation] = []
    @ObservationIgnored private var work: Task<Void, Never>?

    init(store: MobilePushRegistrationStore, environment: PushEnvironment,
         requestToken: @escaping () -> Void,
         register: @escaping (ChannelAPI, PushRegistration) async throws -> Bool = {
             try await $0.register($1)
         },
         remove: @escaping (ChannelAPI, String) async throws -> Void = {
             try await $0.unregister(registrationID: $1)
         },
         subscribe: @escaping (ChannelAPI, String, String) async throws -> Void = {
             try await $0.subscribe(topic: $2, PushSubscription(registrationID: $1))
         },
         unsubscribe: @escaping (ChannelAPI, String, String) async throws -> Void = {
             try await $0.unsubscribe(topic: $2, registrationID: $1)
         }) {
        self.store = store
        self.environment = environment
        self.requestToken = requestToken
        self.register = register
        self.remove = remove
        self.subscribe = subscribe
        self.unsubscribe = unsubscribe
        current = store.current
    }

    @discardableResult
    func select(api: ChannelAPI) throws -> Bool {
        let previous = current
        let selected = try store.select(serverURL: api.baseURL.absoluteString)
        let changed = previous?.registrationID != selected.registrationID
        if changed, let previous {
            let oldAPI = try self.api ?? ChannelAPI(serverURL: previous.serverURL)
            removals.append(Operation(api: oldAPI, registrationID: previous.registrationID, input: nil, topics: []))
        }
        self.api = api
        current = selected
        updateDesired()
        obtainTokenIfNeeded()
        return changed && previous != nil
    }

    func update(enabled: Bool, requests: Bool, completions: Bool) {
        let next = Preferences(enabled: enabled, requests: requests, completions: completions)
        if enabled, preferences?.enabled == false { requestedToken = false }
        preferences = next
        updateDesired()
        obtainTokenIfNeeded()
    }

    func receivedToken(_ data: Data) {
        guard !data.isEmpty else {
            failedToReceiveToken("Apple returned an empty notification token.")
            return
        }
        let next = data.map { String(format: "%02x", $0) }.joined()
        guard token != next else { return }
        token = next
        requestedToken = false
        updateDesired()
    }

    func failedToReceiveToken(_ message: String) {
        requestedToken = true
        error = message
        logger.error("Could not obtain an APNs token: \(message)")
    }

    func retry() {
        error = nil
        requestedToken = false
        attempted = nil
        updateDesired()
        obtainTokenIfNeeded()
    }

    func waitUntilIdle() async { await work?.value }

    private func obtainTokenIfNeeded() {
        guard api != nil, token == nil, !requestedToken else { return }
        requestedToken = true
        requestToken()
    }

    private func updateDesired() {
        let next: Operation?
        if let api, let current, let token {
                let topics = preferences?.enabled == true
                    ? [(preferences?.requests == true ? "requests" : nil),
                       (preferences?.completions == true ? "completions" : nil)].compactMap { $0 } : []
                next = Operation(api: api, registrationID: current.registrationID,
                                 input: PushRegistration(
                                    registrationID: current.registrationID, token: token, environment: environment),
                                 topics: topics)
        } else {
            next = nil
        }
        if desired != next { error = nil }
        desired = next
        schedule()
    }

    private func schedule() {
        guard work == nil, !removals.isEmpty || (desired != nil && desired != attempted) else { return }
        work = Task { [weak self] in
            guard let self else { return }
            await apply()
            work = nil
        }
    }

    private func apply() async {
        while true {
            if !removals.isEmpty {
                let old = removals.removeFirst()
                do { try await remove(old.api, old.registrationID) }
                catch { logger.warning("Could not remove the previous server's registration: \(error.localizedDescription)") }
                continue
            }
            guard let operation = desired, operation != attempted else { return }
            attempted = operation
            do {
                if let input = operation.input {
                    let created = try await register(operation.api, input)
                    if desired != operation { continue }
                    if created, let current, current.registrationID == operation.registrationID {
                        await onCreated?(current)
                        if desired != operation { continue }
                    }
                    var resend = created
                    if !created { resend = try store.acknowledgedTopics(registrationID: operation.registrationID) != operation.topics }
                    if resend {
                        for topic in ["requests", "completions"] {
                            if operation.topics.contains(topic) {
                                try await subscribe(operation.api, operation.registrationID, topic)
                            } else {
                                try await unsubscribe(operation.api, operation.registrationID, topic)
                            }
                        }
                        try store.acknowledge(topics: operation.topics, registrationID: operation.registrationID)
                    }
                }
                else { try await remove(operation.api, operation.registrationID) }
                if desired == operation { error = nil }
            } catch {
                logger.error("Could not update notification registration: \(error.localizedDescription)")
                if desired == operation { self.error = error.localizedDescription }
            }
        }
    }
}
