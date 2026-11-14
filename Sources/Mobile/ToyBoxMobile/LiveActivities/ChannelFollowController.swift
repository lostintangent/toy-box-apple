import ToyBoxClient
import ToyBoxKit
import Foundation
import Observation
import OSLog
import ToyBoxMobileIntegrations

@MainActor @Observable
final class ChannelFollowController {
    /// A server as Follow sees it: its catalog and its own push registration.
    struct Server: Equatable {
        let catalog: ChannelCatalogStore
        var registration: MobilePushRegistration?
        var isRegistrationReady = false
        var registrationError: String?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.catalog === rhs.catalog && lhs.registration == rhs.registration
                && lhs.isRegistrationReady == rhs.isRegistrationReady && lhs.registrationError == rhs.registrationError
        }

        @MainActor fileprivate var address: String? {
            ChannelTarget.normalizedServer(catalog.api.baseURL.absoluteString)
        }

        /// The registration, once it's this server's.
        @MainActor fileprivate var current: MobilePushRegistration? {
            guard let registration, let address,
                  ChannelTarget.normalizedServer(registration.serverURL) == address else { return nil }
            return registration
        }

        @MainActor fileprivate var isReady: Bool { isRegistrationReady && current != nil }
    }

    var startFailed = false

    /// Each server by its normalized address.
    private var servers: [String: Server] = [:]
    private var entries: [ChannelTarget: Follow] = [:]
    private var starting: Set<ChannelTarget> = []
    @ObservationIgnored private let client: ChannelActivityClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let registerActivity: @MainActor (ChannelStore, String, PushSubscription) async throws -> Void
    @ObservationIgnored private let unregisterActivity: @MainActor (ChannelStore, String) async throws -> Void
    @ObservationIgnored private var writes: [ChannelTarget: Task<Void, Error>] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "dev.toybox.mobile", category: "Follow")

    private final class Follow {
        let target: ChannelTarget
        let activity: any ChannelActivitySession
        let store: ChannelStore
        let registration: MobilePushRegistration
        var token: Data?
        var registeredToken: Data?
        var jobs: [Task<Void, Never>] = []

        init(target: ChannelTarget, activity: any ChannelActivitySession, store: ChannelStore,
             registration: MobilePushRegistration) {
            self.target = target
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

    /// Takes every server's catalog and registration. Removing a server, replacing its registration or
    /// respelling its address ends only that server's follows.
    func configure(servers list: [Server]) {
        var next: [String: Server] = [:]
        for server in list {
            guard let address = server.address, next[address] == nil else { continue }
            next[address] = server
        }
        let previous = servers
        guard next != previous else { return }
        var ended: [Server] = []
        var changed: Set<String> = []
        for (address, old) in previous {
            let new = next[address]
            if new?.catalog.api.baseURL != old.catalog.api.baseURL
                || (old.registration != nil && old.registration?.registrationID != new?.registration?.registrationID) {
                ended.append(old)
                changed.insert(address)
            } else if new?.catalog !== old.catalog || new?.registration != old.registration {
                changed.insert(address)
            }
        }
        changed.formUnion(next.keys.filter { previous[$0] == nil })

        let tracked = Set(entries.values.map { $0.activity.id })
        for old in ended {
            for entry in Array(entries.values) where entry.target.serverURL == old.address { finish(entry) }
            for activity in client.activities() where !tracked.contains(activity.id)
                && activity.attributes.registrationID == old.registration?.registrationID {
                Task { await activity.end(activity.content) }
            }
        }
        for entry in Array(entries.values) where changed.contains(entry.target.serverURL) {
            entry.cancel()
            entries[entry.target] = nil
        }
        starting = starting.filter { !changed.contains($0.serverURL) }
        servers = next
        if !changed.isEmpty { restore() }
        for (address, server) in next where server.isRegistrationReady
            && (previous[address]?.isRegistrationReady != true || changed.contains(address)) {
            guard let registration = server.current else { continue }
            Task { [weak self] in await self?.registerCurrentTokens(for: registration) }
        }
    }

    func state(for store: ChannelStore) -> ChannelFollowAction.Status {
        guard let target = store.target else { return .unavailable(nil) }
        if starting.contains(target) { return .starting }
        if entries[target] != nil { return .following }
        guard let server = servers[target.serverURL], server.catalog.api.baseURL == store.api.baseURL else {
            return .unavailable(nil)
        }
        if store.phase == .deleted { return .unavailable(.deleted) }
        if case .failed = store.phase { return .unavailable(.unreachable) }
        guard store.phase.isConnected, let state = store.state else { return .unavailable(nil) }
        let progress = state.channel.tasks.progress
        guard progress.total > progress.done else { return .unavailable(.noTasksInProgress) }
        guard server.isReady else {
            return .unavailable(server.registrationError == nil ? nil : .pushNotSetUp)
        }
        return .available
    }

    func follow(_ store: ChannelStore) async {
        guard state(for: store) == .available, let target = store.target,
              let registration = servers[target.serverURL]?.current else { return }
        starting.insert(target)
        var entry: Follow?
        do {
            for activity in client.activities()
                where activity.attributes.channelID == store.id
                && activity.attributes.registrationID == registration.registrationID {
                await activity.end(activity.content)
            }
            guard let server = servers[target.serverURL], server.isReady, server.current == registration,
                  server.catalog.api.baseURL == store.api.baseURL,
                  starting.contains(target), store.phase.isConnected, let state = store.state,
                  state.channel.tasks.progress.done < state.channel.tasks.count
            else { throw Failure.obsolete }
            let date = now()
            let activity = try client.request(
                .init(channelID: store.id, channelName: state.channel.name,
                      registrationID: registration.registrationID, startedAt: date),
                .init(state: state, working: server.catalog.working, updatedAt: date)
            )
            let follow = Follow(target: target, activity: activity, store: store, registration: registration)
            entry = follow
            entries[target] = follow
            monitor(follow)
            follow.token = try await Self.firstToken(activity)
            try await register(follow)
            try requireCurrent(follow)
            starting.remove(target)
            monitorTokens(follow)
        } catch {
            let current = entry.map(isCurrent)
                ?? (servers[target.serverURL]?.current == registration && starting.contains(target))
            if let entry, isCurrent(entry) { finish(entry) }
            if current {
                starting.remove(target)
                startFailed = true
                logger.error("Could not follow a channel: \(error.localizedDescription)")
            }
        }
    }

    func registrationCreated(_ registration: MobilePushRegistration) async {
        await registerCurrentTokens(for: registration, force: true)
    }

    func stop(_ store: ChannelStore) {
        guard let target = store.target, let entry = entries[target] else { return }
        finish(entry)
    }

    func shutdown() {
        for entry in entries.values { entry.cancel() }
        entries = [:]
        starting = []
    }

    /// Restores each active Activity to its server's follow. An Activity whose registration no server
    /// has ends, but only once every server knows its registration, so one still loading keeps its own.
    private func restore() {
        let known = !servers.isEmpty && servers.values.allSatisfy { $0.current != nil }
        for activity in client.activities() {
            guard let server = servers.values.first(where: {
                $0.current?.registrationID == activity.attributes.registrationID
            }), let registration = server.current else {
                if known { removeUnrestorable(activity) }
                continue
            }
            guard activity.isActive else { continue }
            let store = server.catalog.channel(id: activity.attributes.channelID)
            guard let target = store.target else { continue }
            if let entry = entries[target] {
                if entry.activity.id != activity.id { removeUnrestorable(activity) }
                continue
            }
            let entry = Follow(target: target, activity: activity, store: store, registration: registration)
            entries[target] = entry
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
        guard let address = ChannelTarget.normalizedServer(registration.serverURL),
              let server = servers[address], server.isReady, server.current == registration else { return }
        for entry in Array(entries.values)
            where entry.registration == registration && !starting.contains(entry.target) {
            await registerExisting(entry, force: force)
        }
    }

    private func registerExisting(_ entry: Follow, token: Data? = nil, force: Bool = false) async {
        guard isCurrent(entry) else { return }
        entry.token = entry.activity.pushToken ?? token ?? entry.token
        guard servers[entry.target.serverURL]?.isRegistrationReady == true, entry.token != nil else { return }
        do {
            try await register(entry, force: force)
        } catch {
            if isCurrent(entry) {
                logger.error("Could not register a followed channel subscription: \(error.localizedDescription)")
            }
        }
    }

    private func register(_ entry: Follow, force: Bool = false) async throws {
        let write = enqueueWrite(target: entry.target) {
            try self.requireCurrent(entry)
            guard self.servers[entry.target.serverURL]?.isRegistrationReady == true else {
                throw Failure.registrationPending
            }
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
        entries[entry.target] = nil
        starting.remove(entry.target)
    }

    private func isCurrent(_ entry: Follow) -> Bool { entries[entry.target] === entry }

    private func requireCurrent(_ entry: Follow) throws {
        try Task.checkCancellation()
        guard isCurrent(entry), servers[entry.target.serverURL]?.current == entry.registration,
              entry.activity.isActive else {
            throw Failure.obsolete
        }
    }

    private func deleteRegistration(_ entry: Follow) {
        let task = enqueueWrite(target: entry.target) {
            try await self.unregisterActivity(entry.store, entry.registration.registrationID)
        }
        Task {
            do { try await task.value }
            catch { logger.error("Could not remove an Activity registration: \(error.localizedDescription)") }
        }
    }

    private func enqueueWrite(target: ChannelTarget,
                              operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
        let previous = writes[target]
        let task = Task {
            if let previous { _ = await previous.result }
            try await operation()
        }
        writes[target] = task
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
