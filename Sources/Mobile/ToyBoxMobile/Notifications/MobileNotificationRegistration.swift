import ToyBoxClient
import ToyBoxKit
import Foundation
import Observation
import OSLog
import ToyBoxMobileIntegrations

/// The phone's push registration on every server. Each server registers and subscribes on its own,
/// so one that's offline never holds up the rest.
@MainActor @Observable
final class MobileNotificationRegistration {
    /// Each server's registration, in Settings order.
    private(set) var current: [MobilePushRegistration] = []
    /// The registrations their servers have accepted for this token, by ID.
    private(set) var ready: Set<String> = []
    /// Each registration's last failure, by ID.
    private(set) var failures: [String: String] = [:]
    /// Why Apple gave no token, which fails every server.
    private(set) var tokenError: String?
    @ObservationIgnored var onCreated: ((MobilePushRegistration) async -> Void)?

    private struct Operation: Equatable {
        let api: ChannelAPI
        let registrationID: String
        let input: PushRegistration
        let topics: [String]?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.api.baseURL == rhs.api.baseURL && lhs.registrationID == rhs.registrationID
                && lhs.input == rhs.input && lhs.topics == rhs.topics
        }
    }

    @ObservationIgnored private let store: MobilePushRegistrationStore
    @ObservationIgnored private let environment: PushEnvironment
    @ObservationIgnored private let register: (ChannelAPI, String, PushRegistration) async throws -> Bool
    @ObservationIgnored private let remove: (ChannelAPI, String) async throws -> Void
    @ObservationIgnored private let subscribe: (ChannelAPI, String, String) async throws -> Void
    @ObservationIgnored private let unsubscribe: (ChannelAPI, String, String) async throws -> Void
    @ObservationIgnored private let requestToken: () -> Void
    @ObservationIgnored private let logger = Logger(subsystem: "dev.toybox.mobile", category: "PushRegistration")
    @ObservationIgnored private var apis: [String: ChannelAPI] = [:]
    @ObservationIgnored private var enabled: Bool?
    @ObservationIgnored private var topics: [String]?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var requestedToken = false
    @ObservationIgnored private var desired: [String: Operation] = [:]
    @ObservationIgnored private var attempted: [String: Operation] = [:]
    @ObservationIgnored private var removals: [String: ChannelAPI] = [:]
    @ObservationIgnored private var work: [String: Task<Void, Never>] = [:]

    init(store: MobilePushRegistrationStore, environment: PushEnvironment,
         requestToken: @escaping () -> Void,
         register: @escaping (ChannelAPI, String, PushRegistration) async throws -> Bool = {
             try await $0.register(registrationID: $1, $2)
         },
         remove: @escaping (ChannelAPI, String) async throws -> Void = {
             try await $0.unregister(registrationID: $1)
         },
         subscribe: @escaping (ChannelAPI, String, String) async throws -> Void = {
             try await $0.subscribe(topic: $2, registrationID: $1, PushSubscription())
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
    }

    /// Tokens failing, or else the first server's failure in Settings order.
    var error: String? { tokenError ?? current.lazy.compactMap { self.failures[$0.registrationID] }.first }

    /// Registers every server, and unregisters any server that's gone once its own write finishes.
    /// Returns the registrations it removed.
    @discardableResult
    func select(apis: [ChannelAPI]) throws -> [MobilePushRegistration] {
        var selected: [MobilePushRegistration] = []
        var selectedAPIs: [String: ChannelAPI] = [:]
        for api in apis {
            let registration = try store.register(serverURL: api.baseURL.absoluteString)
            selected.append(registration)
            selectedAPIs[registration.registrationID] = api
        }
        let removed = store.registrations.filter { selectedAPIs[$0.registrationID] == nil }
        for registration in removed {
            let id = registration.registrationID
            let api = try self.apis[id] ?? ChannelAPI(serverURL: registration.serverURL)
            try store.remove(registrationID: id)
            removals[id] = api
            ready.remove(id)
            failures[id] = nil
            attempted[id] = nil
        }
        self.apis = selectedAPIs
        current = selected
        updateDesired()
        obtainTokenIfNeeded()
        return removed
    }

    func update(enabled: Bool, requests: Bool, completions: Bool) {
        if enabled, self.enabled == false { requestedToken = false }
        self.enabled = enabled
        topics = enabled ? [requests ? "requests" : nil, completions ? "completions" : nil].compactMap { $0 } : []
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
        ready = []
        tokenError = nil
        token = next
        requestedToken = false
        updateDesired()
    }

    func failedToReceiveToken(_ message: String) {
        requestedToken = true
        tokenError = message
        logger.error("Could not obtain an APNs token: \(message)")
    }

    func retry() {
        tokenError = nil
        failures = [:]
        requestedToken = false
        attempted = [:]
        updateDesired()
        obtainTokenIfNeeded()
    }

    func waitUntilIdle() async {
        while let task = work.values.first { await task.value }
    }

    private func obtainTokenIfNeeded() {
        guard !current.isEmpty, token == nil, !requestedToken else { return }
        requestedToken = true
        requestToken()
    }

    private func updateDesired() {
        var next: [String: Operation] = [:]
        if let token {
            for registration in current {
                let id = registration.registrationID
                guard let api = apis[id] else { continue }
                next[id] = Operation(api: api, registrationID: id,
                                     input: PushRegistration(token: token, environment: environment), topics: topics)
            }
        }
        for id in Set(desired.keys).union(next.keys) where desired[id] != next[id] { failures[id] = nil }
        desired = next
        for id in Set(removals.keys).union(desired.keys)
        where work[id] == nil && (removals[id] != nil || desired[id] != attempted[id]) {
            work[id] = Task { [weak self] in
                guard let self else { return }
                await apply(id)
                work[id] = nil
            }
        }
    }

    /// One registration's writes, in order, so a server that's removed mid-write unregisters after it.
    private func apply(_ id: String) async {
        while true {
            if let api = removals.removeValue(forKey: id) {
                do { try await remove(api, id) }
                catch { logger.warning("Could not remove a removed server's registration: \(error.localizedDescription)") }
                continue
            }
            guard let operation = desired[id], operation != attempted[id] else { return }
            attempted[id] = operation
            do {
                let created = try await register(operation.api, id, operation.input)
                if desired[id] != operation { continue }
                ready.insert(id)
                if created, let registration = current.first(where: { $0.registrationID == id }) {
                    await onCreated?(registration)
                    if desired[id] != operation { continue }
                }
                if let topics = operation.topics {
                    for topic in ["requests", "completions"] {
                        if topics.contains(topic) {
                            try await subscribe(operation.api, id, topic)
                        } else {
                            try await unsubscribe(operation.api, id, topic)
                        }
                    }
                }
                if desired[id] == operation { failures[id] = nil }
            } catch {
                logger.error("Could not update notification registration: \(error.localizedDescription)")
                if desired[id] == operation { failures[id] = error.localizedDescription }
            }
        }
    }
}
