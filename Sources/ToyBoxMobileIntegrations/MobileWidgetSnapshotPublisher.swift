import ChannelClient
import ChannelKit
import Foundation
import OSLog
import WidgetKit

@MainActor
public final class MobileWidgetSnapshotPublisher {
    private let file: URL
    private let avatarPNG: @MainActor (ChannelAgent) -> Data?
    private let reload: @MainActor () -> Void
    private var previous: NeedsYouSnapshot?
    private var notificationCatalog: MobileNotificationCatalogCache?
    private var requests: [ChannelWaitingRequest.Identity: ChannelRequestMessage] = [:]
    private var avatars: [String: (ChannelAgent, Data)] = [:]
    private var generation = UUID()
    private let logger = Logger(subsystem: "dev.toybox.mobile", category: "Widget")

    private enum Failure: LocalizedError {
        case unsupportedSnapshot
        var errorDescription: String? { "Toy Box cannot read this version of its saved widget snapshot." }
    }

    public init(directory: URL? = nil, avatarPNG: @escaping @MainActor (ChannelAgent) -> Data?,
                reload: @escaping @MainActor () -> Void = {
                    WidgetCenter.shared.reloadTimelines(ofKind: NeedsYouSnapshot.kind)
                }) throws {
        let directory = try directory ?? MobileSharedContainer.url()
        file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        self.avatarPNG = avatarPNG
        self.reload = reload
        do {
            previous = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
            guard previous?.version == 1 else { throw Failure.unsupportedSnapshot }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            previous = nil
        }
    }

    public func update(catalog: ChannelCatalogStore?, serverURL: String) async throws {
        let token = UUID()
        generation = token
        if previous?.serverURL != serverURL {
            requests = [:]
            avatars = [:]
        }
        guard let catalog, catalog.api.baseURL.absoluteString == serverURL,
              catalog.hasLoaded, catalog.error == nil, catalog.state != nil else {
            var snapshot = previous?.serverURL == serverURL ? previous : nil
            if snapshot != nil { snapshot?.isOffline = true }
            try publish(snapshot ?? NeedsYouSnapshot(
                serverURL: serverURL, updatedAt: .now, isOffline: true, isAvailable: false,
                waitingCount: 0, requests: []
            ))
            return
        }
        let snapshot = try await resolvedSnapshot(catalog: catalog, serverURL: serverURL, token: token,
                                                  allowsPartialHistory: true)
        try publish(snapshot)
    }

    public func refresh(session: URLSession = .shared, now: Date = .now) async throws -> NeedsYouSnapshot? {
        let directory = file.deletingLastPathComponent()
        let selected = try MobilePushRegistrationStore(directory: directory).current
        guard let serverURL = selected?.serverURL ?? previous?.serverURL else { return nil }
        let token = UUID()
        generation = token
        if previous?.serverURL != serverURL {
            requests = [:]
            avatars = [:]
        }
        let snapshot: NeedsYouSnapshot
        do {
            snapshot = try await withThrowingTaskGroup(of: NeedsYouSnapshot.self) { group in
                group.addTask {
                    try await self.fetchedSnapshot(serverURL: serverURL, session: session, token: token)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        } catch {
            if Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled { throw error }
            logger.error("Could not refresh the widget: \(error.localizedDescription)")
            var cached = previous?.serverURL == serverURL ? previous : nil
            if cached != nil { cached?.isOffline = true }
            snapshot = cached ?? NeedsYouSnapshot(
                serverURL: serverURL, updatedAt: now, isOffline: true, isAvailable: false,
                waitingCount: 0, requests: [])
        }
        try Task.checkCancellation()
        guard generation == token,
              try MobilePushRegistrationStore(directory: directory).current == selected else {
            throw CancellationError()
        }
        try publish(snapshot, now: now)
        return previous
    }

    private func fetchedSnapshot(serverURL: String, session: URLSession, token: UUID) async throws -> NeedsYouSnapshot {
        let catalog = ChannelCatalogStore(api: try ChannelAPI(serverURL: serverURL, session: session))
        await catalog.refresh()
        try Task.checkCancellation()
        if let failure = catalog.failure { throw failure }
        return try await resolvedSnapshot(
            catalog: catalog, serverURL: serverURL, token: token, allowsPartialHistory: false)
    }

    private func resolvedSnapshot(catalog: ChannelCatalogStore, serverURL: String, token: UUID,
                                  allowsPartialHistory: Bool) async throws -> NeedsYouSnapshot {
        guard let state = catalog.state else { throw ChannelAPIError.invalidResponse }
        if let registration = try MobilePushRegistrationStore(directory: file.deletingLastPathComponent()).current,
           ChannelWaitingRequest.normalizedServer(registration.serverURL)
            == ChannelWaitingRequest.normalizedServer(serverURL) {
            let cache = MobileNotificationCatalogCache(registration: registration, catalog: state)
            if cache != notificationCatalog {
                try cache.write(directory: file.deletingLastPathComponent())
                notificationCatalog = cache
            }
        }
        let waiting = state.channels.filter { channelStatus($0) == .waiting }
        var resolved: [(channel: Channel, sequence: Int, request: ChannelRequestMessage?, date: Date)] = []
        var offline = false
        var identities: Set<ChannelWaitingRequest.Identity> = []
        for channel in waiting {
            guard let sequence = channel.requestSequence, sequence < Int.max,
                  let identity = ChannelWaitingRequest.Identity(
                    serverURL: serverURL, channelID: channel.id, sequence: sequence
                  ) else { throw ChannelAPIError.invalidMessage("A waiting request has an invalid sequence.") }
            identities.insert(identity)
            let store = catalog.channel(id: channel.id)
            let agents = [ChannelAgent.lead(id: channel.id, profile: state.lead)]
                + state.members.filter { $0.channelId == channel.id }
            var request = ChannelWaitingRequest.message(at: sequence, live: store.request,
                                                       agents: store.roster, cached: requests[identity])
            if request == nil {
                do {
                    let history = try await catalog.api.history(channelId: channel.id, before: sequence + 1)
                    if let message = history.messages.first(where: { $0.sequence == sequence }) {
                        request = ChannelRequestMessage(message: message, agents: agents)
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError
                        || (error as? URLError)?.code == .cancelled { throw error }
                    if !allowsPartialHistory { throw error }
                    offline = true
                    logger.error("Could not load a widget request: \(error.localizedDescription)")
                }
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            if let resolvedRequest = request {
                request = ChannelRequestMessage(message: resolvedRequest.message,
                                                agents: store.isLoaded ? store.roster : agents)
            }
            requests[identity] = request
            resolved.append((channel, sequence, request, request.flatMap { ChannelDates.date($0.message.timestamp) }
                             ?? ChannelDates.date(channel.updatedAt) ?? .distantPast))
        }
        requests = requests.filter { identities.contains($0.key) }
        let rows = resolved.sorted { $0.date > $1.date }.prefix(5).map { item in
            let request = item.request
            let requester = request?.requester
            let text = request.map { NotificationText.plainText($0.message.text) } ?? ""
            let quote = text.isEmpty ? request.map {
                NotificationText.requestBody($0.message, agents: $0.agents)
            } ?? "Needs your reply" : text
            return NeedsYouSnapshot.Request(
                channelID: item.channel.id, channelName: item.channel.name,
                sequence: item.sequence, quote: quote,
                agentName: requester?.name, requestedAt: request.flatMap { ChannelDates.date($0.message.timestamp) },
                avatarPNG: requester.flatMap(avatar)
            )
        }
        return NeedsYouSnapshot(
            serverURL: serverURL, updatedAt: .now, isOffline: offline, isAvailable: true,
            waitingCount: waiting.count, requests: rows
        )
    }

    func publish(_ proposed: NeedsYouSnapshot, now: Date = .now) throws {
        var snapshot = proposed
        if let previous {
            snapshot.updatedAt = previous.updatedAt
            if snapshot == previous,
               snapshot.isOffline || now.timeIntervalSince(previous.updatedAt) < 15 * 60 { return }
        }
        if !snapshot.isOffline {
            snapshot.updatedAt = now
        } else if previous?.serverURL != snapshot.serverURL {
            snapshot.updatedAt = proposed.updatedAt
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        previous = snapshot
        reload()
    }

    private func avatar(_ agent: ChannelAgent) -> Data? {
        let identity = ChannelAgent(id: agent.id, name: agent.name, avatar: agent.avatar, deleted: agent.deleted)
        if let cached = avatars[agent.id], cached.0 == identity { return cached.1 }
        guard let data = avatarPNG(identity) else {
            logger.error("Could not render a widget avatar.")
            return nil
        }
        avatars[agent.id] = (identity, data)
        return data
    }
}
