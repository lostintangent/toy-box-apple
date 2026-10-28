import ChannelClient
import ChannelKit
import Foundation
import Observation
import OSLog
import ToyBoxMobileIntegrations

@MainActor @Observable
final class ChannelFollowController {
    static let maximumLifetime: TimeInterval = 8 * 60 * 60
    static let retainedEndingInterval: TimeInterval = 15 * 60
    static let startTimesKey = "followedActivityStartedAt"
    var startFailed = false

    private var entries: [String: Follow] = [:]
    private var starting: Set<String> = []
    @ObservationIgnored private let client: ChannelActivityClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let registerActivity: @MainActor (ChannelStore, String, PushSubscription) async throws -> Void
    @ObservationIgnored private let unregisterActivity: @MainActor (ChannelStore, String) async throws -> Void
    private var registration: MobilePushRegistration?
    private var isRegistrationReady = false
    private var catalog: ChannelCatalogStore?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var acquire: (ChannelStore) -> Void = { _ in }
    @ObservationIgnored private var release: (ChannelStore) -> Void = { _ in }
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var writes: [String: (id: UUID, task: Task<Void, Error>)] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "dev.toybox.mobile", category: "Follow")

    private final class Follow {
        let activity: any ChannelActivitySession
        let store: ChannelStore
        let registration: MobilePushRegistration
        let startedAt: Date
        let release: (ChannelStore) -> Void
        var token: Data?
        var pendingToken: Data?
        var jobs: [Task<Void, Never>] = []
        var observation: Task<Void, Never>?
        var update: Task<Void, Never>?
        var pending: ChannelActivityAttributes.ContentState?

        init(activity: any ChannelActivitySession, store: ChannelStore,
             registration: MobilePushRegistration, startedAt: Date, release: @escaping (ChannelStore) -> Void) {
            self.activity = activity
            self.store = store
            self.registration = registration
            self.startedAt = startedAt
            self.release = release
        }

        func cancel() {
            for job in jobs { job.cancel() }
            observation?.cancel()
            update?.cancel()
        }
    }

    private enum Failure: Error {
        case missingToken, registrationPending, obsolete
    }

    init(client: ChannelActivityClient = .system, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = { .now },
         registerActivity: @escaping @MainActor (ChannelStore, String, PushSubscription) async throws -> Void = {
             try await $0.api.subscribe(topic: "channel:\($0.id)", registrationID: $1, $2)
         },
         unregisterActivity: @escaping @MainActor (ChannelStore, String) async throws -> Void = {
             try await $0.api.unsubscribe(topic: "channel:\($0.id)", registrationID: $1)
         }) {
        self.client = client
        self.defaults = defaults
        self.now = now
        self.registerActivity = registerActivity
        self.unregisterActivity = unregisterActivity
    }

    func configure(registration: MobilePushRegistration?, isRegistrationReady: Bool,
                   catalog: ChannelCatalogStore?, isActive: Bool,
                   acquire: @escaping (ChannelStore) -> Void, release: @escaping (ChannelStore) -> Void) {
        let changed = self.registration != registration || self.catalog !== catalog
        let becameReady = isRegistrationReady && (!self.isRegistrationReady || changed)
        if changed {
            let registrationChanged = self.registration.map {
                $0.registrationID != registration?.registrationID
            } ?? false
            let serverChanged = self.catalog.map { $0.api.baseURL != catalog?.api.baseURL } ?? false
            if registrationChanged || serverChanged {
                let tracked = Set(entries.values.map { $0.activity.id })
                for entry in Array(entries.values) { finish(entry, ending: .serverChanged, immediately: true) }
                for activity in client.activities() where !tracked.contains(activity.id) {
                    startTimes[activity.id] = nil
                    Task { await activity.end(activity.content, dismissAt: nil) }
                }
            } else {
                shutdown()
            }
            starting = []
            self.registration = registration
            self.catalog = catalog
            self.acquire = acquire
            self.release = release
        }
        self.isRegistrationReady = isRegistrationReady
        self.isActive = isActive
        catalogTask?.cancel()
        refreshTask?.cancel()
        for entry in entries.values {
            entry.observation?.cancel()
            entry.observation = nil
        }
        if changed { restore() }
        if becameReady, let registration = currentRegistration {
            Task { [weak self] in await self?.registerCurrentTokens(for: registration) }
        }
        guard isActive else { return }
        for entry in Array(entries.values) {
            if !entry.activity.isActive { forget(entry) }
            else if now().timeIntervalSince(entry.startedAt) >= Self.maximumLifetime {
                finish(entry, ending: .expired)
            } else { observe(entry) }
        }
        observeCatalog()
        refreshTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5 * 60))
                    guard let self else { return }
                    for entry in Array(self.entries.values) { self.refresh(entry) }
                }
            } catch is CancellationError {
            } catch {
                self?.logger.error("Could not refresh followed channels: \(error.localizedDescription)")
            }
        }
    }

    func state(for store: ChannelStore) -> ChannelFollowAction.State {
        if starting.contains(store.id) { return .starting }
        if entries[store.id] != nil { return .following }
        guard isRegistrationReady, currentRegistration != nil, catalog?.api.baseURL == store.api.baseURL,
              store.phase.isLive, let state = store.state else { return .unavailable }
        let progress = channelTasksProgress(state.channel.tasks)
        return progress.total > progress.done ? .available : .unavailable
    }

    func follow(_ store: ChannelStore) async {
        guard state(for: store) == .available, let registration = currentRegistration else { return }
        starting.insert(store.id)
        var entry: Follow?
        do {
            for activity in client.activities() where activity.attributes.channelID == store.id {
                await activity.end(activity.content, dismissAt: nil)
            }
            guard isRegistrationReady, self.registration == registration, self.catalog?.api.baseURL == store.api.baseURL,
                  starting.contains(store.id), store.phase.isLive, let state = store.state,
                  channelTasksProgress(state.channel.tasks).done < state.channel.tasks.count
            else { throw Failure.obsolete }
            let date = now()
            let activity = try client.request(
                .init(channelID: store.id, channelName: state.channel.name,
                      registrationID: registration.registrationID),
                .init(state: state, updatedAt: date)
            )
            startTimes[activity.id] = date.timeIntervalSince1970
            let follow = Follow(activity: activity, store: store, registration: registration,
                                startedAt: date, release: release)
            entry = follow
            entries[store.id] = follow
            acquire(store)
            monitor(follow)
            let token = try await Self.firstToken(activity)
            try requireCurrent(follow)
            try await register(token, for: follow)
            try requireCurrent(follow)
            starting.remove(store.id)
            monitorTokens(follow)
            if isActive { observe(follow) }
        } catch {
            let current = entry.map(isCurrent) ?? (self.registration == registration && starting.contains(store.id))
            if let entry, isCurrent(entry) { finish(entry, ending: .stopped, immediately: true) }
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
        finish(entry, ending: .stopped, immediately: true)
    }

    func shutdown() {
        catalogTask?.cancel()
        refreshTask?.cancel()
        for entry in entries.values {
            entry.cancel()
            entry.release(entry.store)
        }
        entries = [:]
        starting = []
    }

    private var startTimes: [String: Double] {
        get { defaults.dictionary(forKey: Self.startTimesKey) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: Self.startTimesKey) }
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
            guard entries[activity.attributes.channelID] == nil,
                  let timestamp = startTimes[activity.id], timestamp.isFinite,
                  timestamp <= now().timeIntervalSince1970 else {
                removeUnrestorable(activity)
                continue
            }
            let store = catalog.channel(id: activity.attributes.channelID)
            let entry = Follow(activity: activity, store: store, registration: registration,
                               startedAt: Date(timeIntervalSince1970: timestamp), release: release)
            entries[store.id] = entry
            acquire(store)
            monitor(entry)
            monitorTokens(entry)
        }
    }

    private func removeUnrestorable(_ activity: any ChannelActivitySession) {
        startTimes[activity.id] = nil
        logger.notice("Removing an Activity without a current server registration or original start time.")
        Task { await activity.end(activity.content, dismissAt: nil) }
    }

    private func observeCatalog() {
        guard let catalog else { return }
        catalogTask = Task { [weak self] in
            for await (loaded, failed, ids) in Observations({
                (catalog.hasLoaded, catalog.error != nil, Set(catalog.channels.map(\.id)))
            }) {
                guard !Task.isCancelled, let self else { return }
                guard loaded, !failed else { continue }
                for entry in Array(self.entries.values) where !ids.contains(entry.store.id) {
                    self.finish(entry, ending: .channelDeleted, immediately: true)
                }
                for activity in self.client.activities() where !ids.contains(activity.attributes.channelID) {
                    await activity.end(activity.content, dismissAt: nil)
                }
            }
        }
    }

    private func observe(_ entry: Follow) {
        entry.observation?.cancel()
        let store = entry.store
        entry.observation = Task { [weak self, weak entry] in
            for await _ in Observations({ (store.state, store.phase) }) {
                guard !Task.isCancelled, let self, let entry, self.isCurrent(entry) else { return }
                self.refresh(entry)
            }
        }
    }

    private func refresh(_ entry: Follow) {
        guard isCurrent(entry), isActive else { return }
        if entry.store.phase == .deleted {
            finish(entry, ending: .channelDeleted, immediately: true)
        } else if now().timeIntervalSince(entry.startedAt) >= Self.maximumLifetime {
            finish(entry, ending: .expired)
        } else if entry.store.phase.isLive, let state = entry.store.state {
            let content = ChannelActivityAttributes.ContentState(state: state, updatedAt: now())
            if let ending = content.ending { finish(entry, ending: ending, content: content) }
            else { enqueue(content, for: entry) }
        }
    }

    private func enqueue(_ state: ChannelActivityAttributes.ContentState, for entry: Follow) {
        entry.pending = state
        guard entry.update == nil else { return }
        entry.update = Task { [weak self, weak entry] in
            guard let entry else { return }
            while let self, self.isCurrent(entry), self.isActive, let state = entry.pending {
                entry.pending = nil
                await entry.activity.update(state)
            }
            entry.update = nil
        }
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
        let remaining = max(0, Self.maximumLifetime - now().timeIntervalSince(entry.startedAt))
        entry.jobs.append(Task { [weak self, weak entry] in
            do {
                try await Task.sleep(for: .seconds(remaining))
                guard let self, let entry, self.isCurrent(entry) else { return }
                self.finish(entry, ending: .expired)
            } catch is CancellationError {
            } catch {
                self?.logger.error("Could not end an expired follow: \(error.localizedDescription)")
            }
        })
    }

    private func monitorTokens(_ entry: Follow) {
        let activity = entry.activity
        entry.jobs.append(Task { [weak self, weak entry] in
            if let token = activity.pushToken, let self, let entry, self.isCurrent(entry) {
                await self.rotate(token, for: entry)
            }
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled, let self, let entry, self.isCurrent(entry) else { return }
                await self.rotate(token, for: entry)
            }
        })
    }

    private func registerCurrentTokens(for registration: MobilePushRegistration, force: Bool = false) async {
        guard isRegistrationReady, registration == currentRegistration else { return }
        for entry in Array(entries.values)
            where entry.registration == registration && !starting.contains(entry.store.id) {
            guard let token = entry.activity.pushToken ?? entry.pendingToken ?? entry.token else { continue }
            await rotate(token, for: entry, force: force)
        }
    }

    private func rotate(_ token: Data, for entry: Follow, force: Bool = false) async {
        guard isCurrent(entry), force || token != entry.token else { return }
        guard !token.isEmpty else {
            logger.error("ActivityKit supplied an empty rotated push token.")
            return
        }
        entry.pendingToken = token
        guard isRegistrationReady else { return }
        do {
            try requireCurrent(entry)
            try await register(token, for: entry, force: force)
        } catch {
            if isCurrent(entry) {
                logger.error("Could not register a followed channel subscription: \(error.localizedDescription)")
            }
        }
    }

    private func register(_ token: Data, for entry: Follow, force: Bool = false) async throws {
        let input = PushSubscription(
            token: token.map { String(format: "%02x", $0) }.joined(),
            startedAt: entry.startedAt
        )
        let write = enqueueWrite(channelID: entry.store.id) {
            try self.requireCurrent(entry)
            guard self.isRegistrationReady else { throw Failure.registrationPending }
            guard force || token != entry.token else { return }
            try await self.registerActivity(entry.store, entry.registration.registrationID, input)
            try self.requireCurrent(entry)
            entry.token = token
            if entry.pendingToken == token { entry.pendingToken = nil }
        }
        try await write.value
    }

    private func finish(_ entry: Follow, ending: ChannelActivityAttributes.Ending, immediately: Bool = false,
                        content: ChannelActivityAttributes.ContentState? = nil) {
        guard isCurrent(entry) else { return }
        var content = content ?? entry.activity.content
        content.ending = ending
        content.updatedAt = now()
        content.waitingRequestSequence = nil
        forget(entry)
        deleteRegistration(entry)
        let dismissal = immediately ? nil : now().addingTimeInterval(Self.retainedEndingInterval)
        Task {
            await entry.activity.end(content, dismissAt: dismissal)
        }
    }

    private func forget(_ entry: Follow) {
        guard isCurrent(entry) else { return }
        entry.cancel()
        entries[entry.store.id] = nil
        starting.remove(entry.store.id)
        startTimes[entry.activity.id] = nil
        entry.release(entry.store)
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
        let previous = writes[channelID]?.task
        let id = UUID()
        let task = Task {
            if let previous { _ = await previous.result }
            try await operation()
        }
        writes[channelID] = (id, task)
        Task { [weak self] in
            _ = await task.result
            if self?.writes[channelID]?.id == id { self?.writes[channelID] = nil }
        }
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
