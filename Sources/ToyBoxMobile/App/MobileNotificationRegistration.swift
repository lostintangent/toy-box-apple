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

    private struct Preferences: Equatable {
        var enabled: Bool
        var requests: Bool
        var completions: Bool
    }

    private struct Operation: Equatable {
        let api: ChannelAPI
        let registrationID: String
        let input: PushDeviceRegistration?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.api.baseURL == rhs.api.baseURL && lhs.registrationID == rhs.registrationID
                && lhs.input == rhs.input
        }
    }

    @ObservationIgnored private let store: MobilePushRegistrationStore
    @ObservationIgnored private let environment: PushEnvironment
    @ObservationIgnored private let register: (ChannelAPI, PushDeviceRegistration) async throws -> Void
    @ObservationIgnored private let remove: (ChannelAPI, String) async throws -> Void
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
         register: @escaping (ChannelAPI, PushDeviceRegistration) async throws -> Void = {
             try await $0.registerPushDevice($1)
         },
         remove: @escaping (ChannelAPI, String) async throws -> Void = {
             try await $0.deletePushDevice(registrationID: $1)
         }) {
        self.store = store
        self.environment = environment
        self.requestToken = requestToken
        self.register = register
        self.remove = remove
        current = store.current
    }

    @discardableResult
    func select(api: ChannelAPI) throws -> Bool {
        let previous = current
        let selected = try store.select(serverURL: api.baseURL.absoluteString)
        let changed = previous?.registrationID != selected.registrationID
        if changed, let previous {
            let oldAPI = try self.api ?? ChannelAPI(serverURL: previous.serverURL)
            removals.append(Operation(api: oldAPI, registrationID: previous.registrationID, input: nil))
        }
        self.api = api
        current = selected
        updateDesired()
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
        guard preferences?.enabled == true, token == nil, !requestedToken else { return }
        requestedToken = true
        requestToken()
    }

    private func updateDesired() {
        let next: Operation?
        if let api, let current, let preferences {
            if !preferences.enabled {
                next = Operation(api: api, registrationID: current.registrationID, input: nil)
            } else if let token {
                next = Operation(api: api, registrationID: current.registrationID,
                                 input: PushDeviceRegistration(
                                    registrationID: current.registrationID, token: token, environment: environment,
                                    requests: preferences.requests, completions: preferences.completions))
            } else {
                next = nil
            }
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
                if let input = operation.input { try await register(operation.api, input) }
                else { try await remove(operation.api, operation.registrationID) }
                if desired == operation { error = nil }
            } catch {
                logger.error("Could not update notification registration: \(error.localizedDescription)")
                if desired == operation { self.error = error.localizedDescription }
            }
        }
    }
}
