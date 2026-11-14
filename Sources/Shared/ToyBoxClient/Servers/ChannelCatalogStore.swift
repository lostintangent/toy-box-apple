import ToyBoxKit
import Foundation
import Observation

/// See Connections in docs/spec.md. A quick reconnect never changes the catalog's phase, so it's
/// `.connecting` only before its first outcome.
public enum ChannelCatalogPhase: Equatable, Sendable {
    case connecting
    /// The last catalog arrived, and the stream has failed for less than the grace since.
    case connected
    /// A refresh someone asked for failed, or the stream failed for the grace. Retrying continues. It
    /// keeps the typed error, since a sign-in failure reports differently and the widget rethrows it.
    case failed(any Error)

    public var failure: (any Error)? {
        guard case .failed(let error) = self else { return nil }
        return error
    }
    public var message: String? { failure?.localizedDescription }

    /// A failure that repeats the current one is equal to it, so attempts that keep failing the same
    /// way don't notify on each one.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.connecting, .connecting), (.connected, .connected): true
        case let (.failed(lhs), .failed(rhs)):
            if let lhs = lhs as? ChannelAPIError, let rhs = rhs as? ChannelAPIError { lhs == rhs }
            else { type(of: lhs) == type(of: rhs) && lhs.localizedDescription == rhs.localizedDescription }
        default: false
        }
    }
}

@MainActor @Observable
public final class ChannelCatalogStore {
    public let api: ChannelAPI
    /// The server's name in Settings and its section header: the last name the server answered this
    /// run, or its host before it answers.
    public internal(set) var name: String
    /// The server's accent from its last answer, `#` and six hex digits, or nil before it answers.
    /// Nothing shows it yet, and it isn't saved.
    public internal(set) var accentColor: String?
    /// The list this server is in, which each answer reaches, so a new name or peers show.
    @ObservationIgnored weak var servers: ChannelServers?
    public private(set) var state: ChannelCatalog?
    public var channels: [Channel] { state?.channels ?? [] }
    public var members: [ChannelAgent] { state?.members ?? [] }
    /// The server's release, and checking for a newer one and restarting onto it.
    public let update: ServerUpdate
    /// The IDs of the agents running now on this server, the one source of who's working in every
    /// channel. It's empty while the catalog is unavailable, so activity clears instead of going stale.
    public private(set) var working: Set<String> = []
    public private(set) var isActive = true
    public private(set) var phase: ChannelCatalogPhase = .connecting {
        didSet {
            syncWorking()
            syncReconnecting()
        }
    }
    /// Whether a catalog has arrived. It stays true through failures, so the rows stay.
    public var isLoaded: Bool { state != nil }
    /// When the catalog was last known current. Each catalog and change the stream delivers moves it,
    /// and so does a keepalive once `keepaliveRefreshInterval` has passed. Nil until the first catalog.
    public private(set) var lastRefreshedAt: Date?
    /// Keepalives change nothing, so they move `lastRefreshedAt` no more often than the old idle poll
    /// did. Its observers then wake on a quiet server no more than they used to.
    static let keepaliveRefreshInterval: TimeInterval = 15
    /// When a keepalive may next move `lastRefreshedAt`, by `now`.
    @ObservationIgnored private var keepaliveRefreshDue: Date?
    @ObservationIgnored private var stream: Task<Void, Never>?
    @ObservationIgnored private var pathWatch: Task<Void, Never>?
    @ObservationIgnored private let networkPath: NetworkPathSource
    @ObservationIgnored private var detailStores: [String: ChannelStore] = [:]
    /// Called with the channel's ID after the server accepts each send, retries included.
    @ObservationIgnored public var onSendConfirmed: (@MainActor (String) -> Void)?
    /// The app's outbox. Setting it makes this catalog deliver its server's messages.
    @ObservationIgnored public var outbox: ChannelOutbox? {
        didSet {
            guard oldValue !== outbox else { return }
            oldValue?.detach(self)
            for store in detailStores.values { store.outbox = outbox }
            outbox?.attach(self)
        }
    }
    @ObservationIgnored private var catalogGeneration = UUID()
    @ObservationIgnored private var streamGeneration = UUID()
    /// The stream delivered a catalog and hasn't failed since. Only then does a keepalive mean the
    /// catalog is current.
    @ObservationIgnored private(set) var isLive = false
    /// The stream loop is waiting out a backoff with no request under way, so a prompt retry can
    /// start over without cancelling anything.
    @ObservationIgnored private var isBackingOff = false
    @ObservationIgnored private let reconnectPolicy: ReconnectPolicy
    /// When the stream began failing without reporting it.
    @ObservationIgnored private var failingSince: Date?
    @ObservationIgnored private let now: () -> Date
    /// A refresh is waiting for the stream's next catalog or failure, so that failure reports at once.
    /// Internal and observed, so tests can wait for a refresh to reach the stream.
    private(set) var isRequested = false
    /// A refresh is in flight. When it ends, the refreshes that joined it return.
    /// Internal, so no view spins for background work. Tests wait on it.
    private(set) var isFetching = false {
        didSet {
            guard !isFetching else { return }
            let joined = joiners
            joiners = []
            for joiner in joined { joiner.resume() }
        }
    }
    @ObservationIgnored private var joiners: [CheckedContinuation<Void, Never>] = []
    /// Whether the catalog's stream is open or retrying, from `startPolling()` until `stopPolling()`.
    /// Internal and unobserved, so tests can check a stop.
    var isStreaming: Bool { stream != nil }

    /// `now` measures the grace and the keepalive interval. Tests pass a clock they move instead of
    /// waiting, and a network path they change.
    public init(api: ChannelAPI, name: String? = nil, reconnectPolicy: ReconnectPolicy = .init(),
                now: @escaping () -> Date = { .now }, networkPath: NetworkPathSource = .system) {
        self.api = api
        self.name = name ?? Self.name(of: api.baseURL.absoluteString)
        self.update = ServerUpdate(api: api)
        self.reconnectPolicy = reconnectPolicy
        self.now = now
        self.networkPath = networkPath
        update.catalog = self
    }
    deinit {
        stream?.cancel()
        pathWatch?.cancel()
    }

    public func channel(id: String) -> ChannelStore {
        if let existing = detailStores[id] { return existing }
        let store = ChannelStore(id: id, api: api, reconnectPolicy: reconnectPolicy)
        store.outbox = outbox
        store.working = working
        detailStores[id] = store
        return store
    }

    /// A channel's store, only if something already asked for it.
    public func existingChannel(id: String) -> ChannelStore? { detailStores[id] }

    /// A refresh someone asked for, which joins one already in flight instead of returning early.
    /// While the stream is open it reopens the stream and returns with the fresh catalog that opens
    /// it, or reports the failure at once, since the caller waits on the outcome. Like every
    /// connection, the reopened stream reads the server too, so a rename made elsewhere shows.
    /// Without a stream, as in the widget and share extensions, it fetches the catalog once.
    public func refresh() async {
        if isFetching { return await withCheckedContinuation { joiners.append($0) } }
        if stream != nil {
            isRequested = true
            isFetching = true
            openStream()
            return await withCheckedContinuation { joiners.append($0) }
        }
        let token = UUID()
        catalogGeneration = token
        isFetching = true
        defer { if catalogGeneration == token { isFetching = false } }
        do {
            let catalog = try await api.catalog()
            // Once the stream delivers a catalog, it's at least as current as this one.
            guard !Task.isCancelled, catalogGeneration == token, !isLive else { return }
            applyCatalog(catalog)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled,
                  catalogGeneration == token, !isLive else { return }
            phase = .failed(error)
        }
    }

    /// A catalog that changes nothing announces only `lastRefreshedAt`, so the sidebar and its rows
    /// don't re-render on every change elsewhere. `@Observable` skips assigning an equal value.
    /// When the server comes back, held channels waiting out a backoff try again at once.
    private func applyCatalog(_ catalog: ChannelCatalog) {
        let recovered = failingSince != nil || phase.failure != nil
        // A read only moves forward, so a catalog the server sent before it had the user's read can't undo it.
        var catalog = catalog
        let seen = Dictionary((state?.channels ?? []).map { ($0.id, $0.seenThrough) }, uniquingKeysWith: max)
        for index in catalog.channels.indices {
            catalog.channels[index].read(through: seen[catalog.channels[index].id] ?? 0)
        }
        state = catalog
        lastRefreshedAt = .now
        keepaliveRefreshDue = now().addingTimeInterval(Self.keepaliveRefreshInterval)
        failingSince = nil
        phase = .connected
        syncWorking()
        outbox?.catalogChanged(self, recovered: recovered)
        guard recovered else { return }
        for store in detailStores.values { store.retryPromptly() }
    }

    /// Tells the server's row whether the app is reconnecting: the stream is open but not live, and
    /// hasn't failed for the grace. Once it's live, `ServerUpdate.catalogConnected()` takes over.
    private func syncReconnecting() {
        if stream == nil || phase.failure != nil { update.catalogDisconnected() }
        else if !isLive { update.catalogReconnecting() }
    }

    /// Shares who's working with every channel's store, so their presence agrees with the sidebar.
    private func syncWorking() {
        working = phase.failure == nil ? Set(state?.working ?? []) : []
        for store in detailStores.values { store.working = working }
    }

    /// Opens the catalog's stream at once and keeps it open, reconnecting after a backoff, until
    /// `stopPolling()`.
    public func startPolling() {
        guard stream == nil else { return }
        failingSince = nil
        watchNetworkPath()
        openStream()
    }

    /// Replaces the stream with a fresh attempt. Its events are read off the main actor and each one
    /// is queued for it as soon as it decodes, so at launch the first catalog isn't held until the
    /// main thread's first free turn, which comes after the first window is built.
    private func openStream() {
        stream?.cancel()
        streamGeneration = UUID()
        let token = streamGeneration
        isLive = false
        isBackingOff = false
        var first: AsyncThrowingStream<SSEItem<ChannelCatalogEvent>, any Error>? = api.subscribeToCatalog()
        let started = now()
        stream = Task.detached(priority: Task.currentPriority) { [weak self] in
            // Reading a stream opens its request, and each stream lives only inside `do`, so leaving
            // it for any reason closes the request.
            var next = first.take()
            var opened = started
            var attempt = 0
            while true {
                do {
                    guard let items = next.take() else { return }
                    for try await item in items {
                        guard await self?.receive(item, token: token) == true else { return }
                        if case .event(.snapshot) = item { attempt = 0 }
                    }
                    throw ChannelAPIError.streamEnded
                } catch {
                    guard let delay = await self?.retry(after: error, attempt: attempt, opened: opened, token: token)
                    else { return }
                    attempt += 1
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                    guard let reopened = await self?.reopen(token: token) else { return }
                    (next, opened) = (reopened.stream, reopened.opened)
                }
            }
        }
        syncReconnecting()
    }

    /// Applies what the stream read. Returns whether reading continues. A change applies only on top
    /// of the catalog this stream delivered.
    private func receive(_ item: SSEItem<ChannelCatalogEvent>, token: UUID) -> Bool {
        guard !Task.isCancelled, streamGeneration == token else { return false }
        switch item {
        case .keepalive:
            guard isLive, let due = keepaliveRefreshDue, now() >= due else { break }
            lastRefreshedAt = .now
            keepaliveRefreshDue = now().addingTimeInterval(Self.keepaliveRefreshInterval)
        case .event(.snapshot(let catalog)):
            let connected = !isLive
            isLive = true
            applyCatalog(catalog)
            settleRequest()
            if connected { update.catalogConnected() }
        case .event(.unknown):
            break
        case .event(let event):
            guard isLive, var catalog = state else { break }
            catalog.apply(event)
            applyCatalog(catalog)
        }
        return true
    }

    /// Records a failed attempt and returns the backoff before the next one. The phase stays as it
    /// is until the stream has failed for the grace, counted from the drop or from an attempt that
    /// never delivered, so a quick reconnect shows nothing. A refresh waiting on it reports at once.
    private func retry(after error: any Error, attempt: Int, opened: Date, token: UUID) -> TimeInterval? {
        guard !Task.isCancelled, streamGeneration == token else { return nil }
        let since = failingSince ?? (isLive ? now() : opened)
        failingSince = since
        isLive = false
        if isRequested || phase.failure != nil || now().timeIntervalSince(since) >= reconnectPolicy.grace {
            phase = .failed(error)
        }
        syncReconnecting()
        settleRequest()
        isBackingOff = true
        return reconnectPolicy.delay(attempt: attempt)
    }

    private func reopen(token: UUID)
        -> (stream: AsyncThrowingStream<SSEItem<ChannelCatalogEvent>, any Error>, opened: Date)? {
        guard !Task.isCancelled, streamGeneration == token else { return nil }
        isBackingOff = false
        return (api.subscribeToCatalog(), now())
    }

    /// Returns the refreshes waiting on the stream's next catalog or failure.
    private func settleRequest() {
        guard isRequested else { return }
        isRequested = false
        isFetching = false
    }

    /// Ends the stream's backoff early. An attempt already under way keeps going.
    private func retryPromptly() {
        guard isBackingOff else { return }
        openStream()
    }

    /// Coming back to the app ends the stream's backoff and every held channel's. A live stream reads
    /// the server, since it may have been renamed meanwhile, and one that isn't reads it on connect.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        guard active else { return }
        if isLive { Task { await refreshServer() } }
        retryPromptly()
        for store in detailStores.values { store.retryPromptly() }
        outbox?.reload(self)
    }

    /// Closes the stream and stops retrying. A refresh waiting on it returns.
    public func stopPolling() {
        streamGeneration = UUID()
        stream?.cancel()
        stream = nil
        isLive = false
        isBackingOff = false
        pathWatch?.cancel()
        pathWatch = nil
        syncReconnecting()
        settleRequest()
    }

    /// While streaming, a network that comes back or moves to another interface gives the stream and
    /// every held channel that isn't connected a fresh attempt instead of its backoff, since an
    /// attempt under way may be stuck on the old path.
    private func watchNetworkPath() {
        let paths = networkPath.paths()
        pathWatch = Task { [weak self] in
            var previous: NetworkPath?
            for await path in paths {
                defer { previous = path }
                guard path.isReturn(from: previous) else { continue }
                guard let self else { return }
                if !isLive { openStream() }
                for store in detailStores.values { store.retryOnNewPath() }
                outbox?.wake(self)
            }
        }
    }
}
