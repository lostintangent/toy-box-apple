import ChannelClient
import ChannelKit
import Foundation
import Observation
import OSLog
import ToyBoxMobileIntegrations

@MainActor @Observable
final class ChannelFollowController {
    var startFailed = false

    private var entries: [String: Follow] = [:]
    private var starting: Set<String> = []
    @ObservationIgnored private let client: ChannelActivityClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let registerActivity: @MainActor (ChannelStore, String, PushSubscription) async throws -> Void
    @ObservationIgnored private let unregisterActivity: @MainActor (ChannelStore, String) async throws -> Void
    private var registration: MobilePushRegistration?
    private var isRegistrationReady = false
    private var catalog: ChannelCatalogStore?
    @ObservationIgnored private var writes: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "dev.toybox.mobile", category: "Follow")

    private final class Follow {
        let activity: any ChannelActivitySession
        let store: ChannelStore
        let registration: MobilePushRegistration
        var token: Data?
        var registeredToken: Data?
        var jobs: [Task<Void, Never>] = []

        init(activity: any ChannelActivitySession, store: ChannelStore, registration: MobilePushRegistration) {
            self.activity = activity
            self.store = store
            self.registration = registration
        }

        func cancel() {
            for job in jobs { job.cancel() }
        }
    }

    private enum Failure: Error {
        case missingToken, registrationPending, obsolete
    }

    init(client: ChannelActivityClient = .system,
         now: @escaping () -> Date = { .now },
         registerActivity: @escaping @MainActor (ChannelStore, String, PushSubscription) async throws -> Void = {
             try await $0.api.subscribe(topic: "channel:\($0.id)", registrationID: $1, $2)
         },
         unregisterActivity: @escaping @MainActor (ChannelStore, String) async throws -> Void = {
             try await $0.api.unsubscribe(topic: "channel:\($0.id)", registrationID: $1)
         }) {
        self.client = client
        self.now = now
        self.registerActivity = registerActivity
        self.unregisterActivity = unregisterActivity
    }

    func configure(registration: MobilePushRegistration?, isRegistrationReady: Bool, catalog: ChannelCatalogStore?) {
        let changed = self.registration != registration || self.catalog !== catalog
        let becameReady = isRegistrationReady && (!self.isRegistrationReady || changed)
        if changed {
            let registrationChanged = self.registration != nil
                && self.registration?.registrationID != registration?.registrationID
            let serverChanged = self.catalog != nil && self.catalog?.api.baseURL != catalog?.api.baseURL
            if registrationChanged || serverChanged {
                let tracked = Set(entries.values.map { $0.activity.id })
                for entry in Array(entries.values) { finish(entry) }
                for activity in client.activities() where !tracked.contains(activity.id) {
                    Task { await activity.end(activity.content) }
                }
            } else {
                shutdown()
            }
            starting = []
            self.registration = registration
            self.catalog = catalog
        }
        self.isRegistrationReady = isRegistrationReady
        if changed { restore() }
        if becameReady, let registration = currentRegistration {
            Task { [weak self] in await self?.registerCurrentTokens(for: registration) }
        }
    }

    func state(for store: ChannelStore) -> ChannelFollowAction.State {
        if starting.contains(store.id) { return .starting }
        if entries[store.id] != nil { return .following }
        guard isRegistrationReady, currentRegistration != nil, catalog?.api.baseURL == store.api.baseURL,
              store.phase.isConnected, let state = store.state else { return .unavailable }
        let progress = channelTasksProgress(state.channel.tasks)
        return progress.total > progress.done ? .available : .unavailable
    }

    func follow(_ store: ChannelStore) async {
        guard state(for: store) == .available, let registration = currentRegistration else { return }
        starting.insert(store.id)
        var entry: Follow?
        do {
            for activity in client.activities() where activity.attributes.channelID == store.id {
                await activity.end(activity.content)
            }
            guard isRegistrationReady, self.registration == registration, self.catalog?.api.baseURL == store.api.baseURL,
                  starting.contains(store.id), store.phase.isConnected, let state = store.state,
                  channelTasksProgress(state.channel.tasks).done < state.channel.tasks.count
            else { throw Failure.obsolete }
            let date = now()
            let activity = try client.request(
                .init(channelID: store.id, channelName: state.channel.name,
                      registrationID: registration.registrationID, startedAt: date),
                .init(state: state, updatedAt: date)
            )
            let follow = Follow(activity: activity, store: store, registration: registration)
            entry = follow
            entries[store.id] = follow
            monitor(follow)
            follow.token = try await Self.firstToken(activity)
            try await register(follow)
            try requireCurrent(follow)
            starting.remove(store.id)
            monitorTokens(follow)
        } catch {
            let current = entry.map(isCurrent) ?? (self.registration == registration && starting.contains(store.id))
            if let entry, isCurrent(entry) { finish(entry) }
            if current {
                starting.remove(store.id)
                startFailed = true
                logger.error("Could not follow a channel: \(error.localizedDescription)")
            }
        }
    }

    func registrationCreated(_ registration: MobilePushRegistration) async {
        await registerCurrentTokens(for: registration, force: true)
    }

    func stop(channelID: String) {
        guard let entry = entries[channelID] else { return }
        finish(entry)
    }

    func shutdown() {
        for entry in entries.values { entry.cancel() }
        entries = [:]
        starting = []
    }

    private var currentRegistration: MobilePushRegistration? {
        guard let registration, let catalog,
              ChannelWaitingRequest.normalizedServer(registration.serverURL)
                == ChannelWaitingRequest.normalizedServer(catalog.api.baseURL.absoluteString)
        else { return nil }
        return registration
    }

    private func restore() {
        guard let registration = currentRegistration, let catalog else { return }
        for activity in client.activities() {
            guard activity.attributes.registrationID == registration.registrationID else {
                removeUnrestorable(activity)
                continue
            }
            guard activity.isActive else { continue }
            guard entries[activity.attributes.channelID] == nil else {
                removeUnrestorable(activity)
                continue
            }
            let store = catalog.channel(id: activity.attributes.channelID)
            let entry = Follow(activity: activity, store: store, registration: registration)
            entries[store.id] = entry
            monitor(entry)
            monitorTokens(entry)
        }
    }

    private func removeUnrestorable(_ activity: any ChannelActivitySession) {
        logger.notice("Removing an Activity without a current server registration.")
        Task { await activity.end(activity.content) }
    }

    private func monitor(_ entry: Follow) {
        let activity = entry.activity
        entry.jobs.append(Task { [weak self, weak entry] in
            for await active in activity.activeUpdates {
                guard !Task.isCancelled, let self, let entry, self.isCurrent(entry) else { return }
                if !active {
                    self.forget(entry)
                    self.deleteRegistration(entry)
                    return
                }
            }
        })
    }

    private func monitorTokens(_ entry: Follow) {
        let activity = entry.activity
        entry.jobs.append(Task { [weak self, weak entry] in
            if let self, let entry { await self.registerExisting(entry) }
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled, let self, let entry, self.isCurrent(entry) else { return }
                await self.registerExisting(entry, token: token)
            }
        })
    }

    private func registerCurrentTokens(for registration: MobilePushRegistration, force: Bool = false) async {
        guard isRegistrationReady, registration == currentRegistration else { return }
        for entry in Array(entries.values)
            where entry.registration == registration && !starting.contains(entry.store.id) {
            await registerExisting(entry, force: force)
        }
    }

    private func registerExisting(_ entry: Follow, token: Data? = nil, force: Bool = false) async {
        guard isCurrent(entry) else { return }
        entry.token = entry.activity.pushToken ?? token ?? entry.token
        guard isRegistrationReady, entry.token != nil else { return }
        do {
            try await register(entry, force: force)
        } catch {
            if isCurrent(entry) {
                logger.error("Could not register a followed channel subscription: \(error.localizedDescription)")
            }
        }
    }

    private func register(_ entry: Follow, force: Bool = false) async throws {
        let write = enqueueWrite(channelID: entry.store.id) {
            try self.requireCurrent(entry)
            guard self.isRegistrationReady else { throw Failure.registrationPending }
            guard let token = entry.activity.pushToken ?? entry.token, !token.isEmpty else {
                throw Failure.missingToken
            }
            guard force || token != entry.registeredToken else { return }
            let input = PushSubscription(
                token: token.map { String(format: "%02x", $0) }.joined(),
                startedAt: entry.activity.attributes.startedAt
            )
            try await self.registerActivity(entry.store, entry.registration.registrationID, input)
            try self.requireCurrent(entry)
            entry.registeredToken = token
        }
        try await write.value
    }

    private func finish(_ entry: Follow) {
        guard isCurrent(entry) else { return }
        forget(entry)
        deleteRegistration(entry)
        Task { await entry.activity.end(entry.activity.content) }
    }

    private func forget(_ entry: Follow) {
        guard isCurrent(entry) else { return }
        entry.cancel()
        entries[entry.store.id] = nil
        starting.remove(entry.store.id)
    }

    private func isCurrent(_ entry: Follow) -> Bool { entries[entry.store.id] === entry }

    private func requireCurrent(_ entry: Follow) throws {
        try Task.checkCancellation()
        guard isCurrent(entry), registration == entry.registration, entry.activity.isActive else {
            throw Failure.obsolete
        }
    }

    private func deleteRegistration(_ entry: Follow) {
        let task = enqueueWrite(channelID: entry.store.id) {
            try await self.unregisterActivity(entry.store, entry.registration.registrationID)
        }
        Task {
            do { try await task.value }
            catch { logger.error("Could not remove an Activity registration: \(error.localizedDescription)") }
        }
    }

    private func enqueueWrite(channelID: String,
                              operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
        let previous = writes[channelID]
        let task = Task {
            if let previous { _ = await previous.result }
            try await operation()
        }
        writes[channelID] = task
        return task
    }

    private static func firstToken(_ activity: any ChannelActivitySession) async throws -> Data {
        if let token = activity.pushToken, !token.isEmpty { return token }
        let updates = activity.pushTokenUpdates
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                for await token in updates where !token.isEmpty { return token }
                throw Failure.missingToken
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw Failure.missingToken
            }
            defer { group.cancelAll() }
            guard let token = try await group.next() else { throw Failure.missingToken }
            return token
        }
    }
}
