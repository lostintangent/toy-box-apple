import ChannelKit
import Foundation
import Observation

/// See Connections in docs/spec.md.
public enum ChannelConnectionPhase: Equatable, Sendable {
    /// Not connected yet and not failed: a first connect, a snapshot still arriving, a quiet retry
    /// within the grace, or a channel nobody holds.
    case connecting
    case connected
    /// The channel tried for a grace in which nothing arrived, without connecting. Retrying
    /// continues, and the phase stays until the stream connects.
    case failed(String)
    case deleted

    public var isConnected: Bool { self == .connected }
    /// Whether the channel failed or was deleted, the only phases that change what's on screen.
    public var isUnavailable: Bool {
        switch self {
        case .failed, .deleted: true
        case .connecting, .connected: false
        }
    }
    public var message: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

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

public struct ChannelManagementReconciliation: Sendable {
    public let catalog: ChannelCatalog
    public let channelId: String?
    public let state: ChannelState?

    public var channelWasDeleted: Bool { channelId != nil && state == nil }

    public init(catalog: ChannelCatalog, channelId: String?, state: ChannelState?) {
        self.catalog = catalog
        self.channelId = channelId
        self.state = state
    }
}

@MainActor @Observable
public final class ChannelStore {
    public let id: String
    public let api: ChannelAPI
    /// The whole channel. Reading it re-evaluates a view on every event, so views read the narrow
    /// slices below instead, and keep `state` for one-off reads in actions and tasks.
    public private(set) var state: ChannelState? {
        didSet { if let state { syncSlices(state) } }
    }

    // Narrow projections of `state`, so an event invalidates only the views that read what it
    // changed. A new message moves `messages` and nothing else.
    public private(set) var details: ChannelDetails?
    /// The lead, then members, as identities. `status` is always nil here, so a status event doesn't
    /// invalidate views that only draw names and avatars. Reported statuses are in `agentStatuses`.
    public private(set) var roster: [ChannelAgent] = []
    /// Each agent's reported status by agent ID, as `ChannelState`'s agents carry it.
    public private(set) var agentStatuses: [String: ChannelAgent.Status] = [:]
    public private(set) var presence: [String: ChannelAgentPresence] = [:]
    public private(set) var messages: [ChannelMessage] = []
    public private(set) var request: ChannelMessage?
    public private(set) var requestSequence: Int?
    public private(set) var tasks: [ChannelTask] = []
    public private(set) var artifacts: [ChannelArtifact] = []
    /// Who shared each artifact and when, by file ID, from the loaded messages.
    public private(set) var artifactShares: [String: ChannelArtifact.Share] = [:]
    public private(set) var routines: [ChannelRoutine] = []
    /// The sequences of the messages the user bookmarked, oldest first, including any change still on
    /// its way to the server. Nil when the server predates bookmarks, so views hide them.
    public private(set) var bookmarks: [Int]?
    /// The bookmarks list, newest first, each with its message once that page of history loads.
    /// Opening the list loads through its last entry, the oldest, with `loadHistory(through:)`.
    public private(set) var bookmarkList: [ChannelBookmark] = []

    /// Whether a snapshot has arrived, without observing anything that changes after it.
    public var isLoaded: Bool { details != nil }

    public private(set) var phase: ChannelConnectionPhase = .connecting
    public private(set) var unreadAfter: Int?
    public private(set) var isLoadingOlder = false
    public private(set) var hasOlderMessages = true
    public private(set) var historyError: String?
    public private(set) var readError: String?
    /// The latest bookmark change that failed and was undone, until the next change or a dismissal.
    public private(set) var bookmarkFailure: BookmarkFailure?
    /// The app's outbox, which delivers every message sent through it. Set by the catalog store.
    @ObservationIgnored public internal(set) weak var outbox: ChannelOutbox?
    /// The messages the outbox still holds for this channel, Sending or Not sent, which the
    /// transcript shows below the server's.
    public var sending: [ChannelOutbox.Message] { outbox?.messages(in: id) ?? [] }

    @ObservationIgnored private var observation: Task<Void, Never>?
    /// From `connect()` until `disconnect()`. Internal and unobserved, so tests check a disconnect
    /// here, since the phase it leaves is `.connecting` either way.
    var isTrying: Bool { observation != nil }
    /// The observation loop is waiting out a backoff with no request under way, so a prompt retry
    /// can start over without cancelling anything.
    @ObservationIgnored private var isBackingOff = false
    @ObservationIgnored private var generation = UUID()
    /// Ends a quiet `.connecting` period once it outlasts the reconnect policy's grace.
    @ObservationIgnored private var grace: Task<Void, Never>?
    /// The latest failure while connecting, which `phase` reports if the grace runs out.
    @ObservationIgnored private var lastFailure: String?
    /// The stream received bytes during the current grace, so the grace waits another round instead
    /// of failing. Internal and observed, so tests can wait for an arrival.
    private(set) var isArriving = false
    /// What a stream opened after the published revision has replayed so far, held until `resumed`
    /// so a channel that moved far ahead catches up in one change instead of replaying on screen.
    /// Nil unless a resume is under way. Internal and observed, so tests can wait for held events.
    private(set) var heldReplay: [ChannelObservationEvent]?
    @ObservationIgnored private var arrivals: StreamArrivals?
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var capturedUnread = false
    @ObservationIgnored private var historyGeneration = UUID()
    @ObservationIgnored private var readWrite: Task<Void, Never>?
    @ObservationIgnored private var pendingRead = 0
    @ObservationIgnored private var acknowledgedRead = 0
    /// Bookmark changes the server hasn't answered yet, by sequence. `bookmarks` shows them over
    /// `state`, so an older list from the stream can't hide one.
    @ObservationIgnored private var bookmarkChanges: [Int: Bool] = [:]
    @ObservationIgnored private var bookmarkWrites: Task<Void, Never>?
    @ObservationIgnored private let reconnectPolicy: ReconnectPolicy

    /// `sleep` waits out each grace. Tests pass one they end instead of waiting.
    public init(id: String, api: ChannelAPI, reconnectPolicy: ReconnectPolicy = .init(),
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.id = id
        self.api = api
        self.reconnectPolicy = reconnectPolicy
        self.sleep = sleep
    }

    deinit {
        observation?.cancel()
        grace?.cancel()
    }

    /// Starts the stream, then keeps retrying until `disconnect()`.
    /// Events are read off the main actor and each one is queued for it as soon as it decodes.
    /// Iterating the stream from the main actor would hop off and back even for a buffered event,
    /// which at launch held the first snapshot until after the window's first render.
    public func connect() {
        guard observation == nil, phase != .deleted else { return }
        generation = UUID()
        let token = generation
        arrivals = StreamArrivals { [weak self] in
            Task { @MainActor [weak self] in self?.streamArrived(token: token) }
        }
        // Retry keeps a failure on screen until the stream connects.
        if phase.message == nil { startGrace(token: token) }
        var first: AsyncThrowingStream<ChannelObservationEvent, any Error>? = openStream()
        observation = Task.detached(priority: Task.currentPriority) { [weak self] in
            // Reading a stream opens its request, so only this loop ever connects, and each stream
            // lives only inside `do`, so leaving it for any reason closes the request.
            var next = first.take()
            var attempt = 0
            while true {
                do {
                    guard let events = next.take() else { return }
                    for try await event in events {
                        guard try await self?.receive(event, token: token) == true else { return }
                        if event.type == "snapshot" || event.type == "resumed" { attempt = 0 }
                    }
                    throw ChannelAPIError.streamEnded
                } catch {
                    guard let delay = await self?.retry(after: error, attempt: attempt, token: token)
                    else { return }
                    attempt += 1
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                    next = await self?.reopen(token: token)
                }
            }
        }
    }

    /// Applies an observed event. Returns whether observation continues.
    private func receive(_ event: ChannelObservationEvent, token: UUID) throws -> Bool {
        guard !Task.isCancelled, generation == token else { return false }
        return try !apply(event)
    }

    /// Records a failed attempt and returns the backoff before the next one. A connected channel
    /// goes back to `.connecting` and a failed one reports the latest failure.
    private func retry(after error: any Error, attempt: Int, token: UUID) -> TimeInterval? {
        guard !Task.isCancelled, generation == token else { return nil }
        switch phase {
        case .connected: startGrace(token: token)
        case .failed: phase = .failed(error.localizedDescription)
        case .connecting, .deleted: break
        }
        lastFailure = error.localizedDescription
        isBackingOff = true
        // The next attempt replays everything after the published revision again.
        heldReplay = nil
        return reconnectPolicy.delay(attempt: attempt)
    }

    private func reopen(token: UUID) -> AsyncThrowingStream<ChannelObservationEvent, any Error>? {
        guard !Task.isCancelled, generation == token else { return nil }
        isBackingOff = false
        return openStream()
    }

    /// Asks for everything after the published revision, or a snapshot when nothing is published.
    private func openStream() -> AsyncThrowingStream<ChannelObservationEvent, any Error> {
        heldReplay = state == nil ? nil : []
        return api.observe(channelId: id, after: state?.revision, arrivals: arrivals)
    }

    private func streamArrived(token: UUID) {
        guard generation == token, phase == .connecting else { return }
        isArriving = true
    }

    /// Says `.connecting` until the stream connects, or until a grace passes in which the loop
    /// tried without connecting and nothing arrived, which reports the latest failure as `.failed`.
    /// Only time spent trying counts, and a grace with bytes in it waits another round, so a large
    /// snapshot on a slow link stays `.connecting` while it arrives.
    private func startGrace(token: UUID) {
        stopGrace()
        phase = .connecting
        let seconds = reconnectPolicy.grace
        let sleep = self.sleep
        grace = Task { [weak self] in
            while true {
                try? await sleep(seconds)
                guard !Task.isCancelled, let self, generation == token, phase == .connecting else { return }
                guard isArriving else {
                    phase = .failed(lastFailure ?? Self.unansweredConnect)
                    return
                }
                isArriving = false
                arrivals?.rearm()
            }
        }
    }

    private func stopGrace() {
        grace?.cancel()
        grace = nil
        lastFailure = nil
        isArriving = false
        arrivals?.rearm()
    }

    static let unansweredConnect = "The server hasn't responded yet. Still trying."

    /// Stops trying. Nothing waits on the phase this leaves, `.connecting` unless deleted.
    public func disconnect() {
        stopTrying()
        if phase != .deleted { phase = .connecting }
    }

    /// Disconnects and returns once the observation loop has ended. Only that loop opens stream
    /// requests, so afterward the store opens none on its own. Tests close a store this way before
    /// invalidating its session, since creating a request on an invalidated session crashes.
    func close() async {
        let loop = observation
        disconnect()
        await loop?.value
    }

    /// Tries again at once. A failed channel stays `.failed` until the stream connects.
    public func reconnect() {
        stopTrying()
        connect()
    }

    /// Ends a backoff early, as when the server or the app comes back. An attempt already under way
    /// keeps going, so a snapshot still arriving never starts over.
    func retryPromptly() {
        guard isBackingOff else { return }
        reconnect()
    }

    /// Starts a fresh attempt for a channel that's trying without being connected, because the
    /// network came back or moved, and an attempt under way may be stuck on the old path.
    func retryOnNewPath() {
        guard isTrying, phase != .connected, phase != .deleted else { return }
        reconnect()
    }

    private func stopTrying() {
        generation = UUID()
        isBackingOff = false
        observation?.cancel()
        observation = nil
        heldReplay = nil
        stopGrace()
    }

    fileprivate func reconcileManagementSnapshot(_ snapshot: ChannelState) throws -> ChannelState {
        if let state, state.revision > snapshot.revision { return state }
        let wasObserving = observation != nil
        disconnect()
        _ = try apply(.init(type: "snapshot", state: snapshot))
        if wasObserving { connect() }
        else { phase = .connecting }
        return snapshot
    }

    fileprivate func reconcileManagementDeletion() {
        disconnect()
        historyGeneration = UUID()
        phase = .deleted
    }

    /// Places the New divider for someone opening the channel. A store that disconnected kept its
    /// last state, so the divider matches those cached rows until the reconnect's snapshot or replay
    /// completes and places it for good.
    public func captureUnreadBoundary() {
        unreadAfter = state.flatMap { $0.channel.unreadAfter }
        capturedUnread = state != nil && phase.isConnected
    }

    public func loadOlder() async {
        guard !isLoadingOlder, hasOlderMessages, let state,
              let first = state.messages.first else { return }
        if first.sequence <= 1 { hasOlderMessages = false; return }
        let historyToken = historyGeneration
        isLoadingOlder = true
        historyError = nil
        defer { isLoadingOlder = false }
        do {
            let page = try await api.history(channelId: id, before: first.sequence)
            guard historyGeneration == historyToken, phase != .deleted else { return }
            if var current = self.state {
                current.messages = current.messages.merging(page.messages)
                self.state = current
            }
            hasOlderMessages = !page.messages.isEmpty && page.messages.first?.sequence != 1
        } catch {
            if historyGeneration == historyToken { historyError = error.localizedDescription }
        }
    }

    /// Pages back until `sequence` is loaded. Stops when history ends, a page fails, a page adds
    /// nothing or a snapshot replaces the history it started paging, so a reveal can never spin.
    /// Returns the failure of the page that stopped it.
    @discardableResult
    public func loadHistory(through sequence: Int) async -> String? {
        let generation = historyGeneration
        while let first = state?.messages.first, first.sequence > sequence && hasOlderMessages {
            let before = first.sequence
            if isLoadingOlder {
                do { try await Task.sleep(for: .milliseconds(40)) }
                catch { return nil }
            } else { await loadOlder() }
            guard !Task.isCancelled, historyGeneration == generation else { return nil }
            if let historyError { return historyError }
            if !isLoadingOlder && state?.messages.first?.sequence == before { return nil }
        }
        return nil
    }

    /// Returns once the read through `sequence`, and any later read raised meanwhile, is written or a
    /// write fails. The store owns the write, so cancelling a caller neither interrupts it nor reports
    /// an error, and a later caller joins it rather than leaving its read for the next scroll.
    public func markRead(through sequence: Int) async {
        guard phase.isConnected, let channel = state?.channel else { return }
        pendingRead = max(pendingRead, min(sequence, channel.latestSequence))
        if readWrite == nil {
            guard pendingRead > max(channel.seenThrough, acknowledgedRead) else { return }
            readError = nil
            readWrite = Task { await writeReads() }
        }
        await readWrite?.value
    }

    private func writeReads() async {
        defer { readWrite = nil }
        while let current = state?.channel, pendingRead > max(current.seenThrough, acknowledgedRead), phase.isConnected {
            let target = pendingRead
            do {
                let seen = try await api.markRead(channelId: id, sequence: target)
                acknowledgedRead = max(acknowledgedRead, seen)
                if seen < target { break }
            } catch {
                readError = error.localizedDescription
                break
            }
        }
    }

    /// Shows the change at once, then writes it into `state` when the server answers, so its echo
    /// changes nothing. A failed write leaves `state` as it was and reports `bookmarkFailure`.
    /// Bookmarking is idempotent, so a write makes one attempt and changing it again is the retry.
    /// Writes run in order, each sending its message's latest change, so the server ends where the
    /// user's last change left it.
    public func setBookmarked(_ bookmarked: Bool, sequence: Int) async {
        guard state?.bookmarks != nil else { return }
        guard phase.isConnected else {
            bookmarkFailure = .init(sequence: sequence, isRemoval: !bookmarked,
                                    error: ChannelAPIError.disconnected.localizedDescription)
            return
        }
        bookmarkFailure = nil
        bookmarkChanges[sequence] = bookmarked
        syncBookmarks()
        let previous = bookmarkWrites
        let write = Task { [weak self] in
            await previous?.value
            await self?.writeBookmark(sequence)
        }
        bookmarkWrites = write
        await write.value
    }

    public func dismissBookmarkFailure() {
        bookmarkFailure = nil
    }

    private func writeBookmark(_ sequence: Int) async {
        // An earlier write already sent this message's latest change.
        guard let bookmarked = bookmarkChanges[sequence] else { return }
        do {
            try await api.bookmark(channelId: id, sequence: sequence, bookmarked: bookmarked)
            state?.setBookmarked(bookmarked, sequence: sequence)
        } catch {
            // A later change to the message is still to be written, and reports its own failure.
            if bookmarkChanges[sequence] == bookmarked {
                bookmarkFailure = .init(sequence: sequence, isRemoval: !bookmarked, error: error.localizedDescription)
            }
        }
        if bookmarkChanges[sequence] == bookmarked { bookmarkChanges[sequence] = nil }
        syncBookmarks()
    }

    private func syncBookmarks() {
        var shown = state
        for (sequence, bookmarked) in bookmarkChanges { shown?.setBookmarked(bookmarked, sequence: sequence) }
        bookmarks = shown?.bookmarks
        bookmarkList = ChannelBookmark.list(shown?.bookmarks ?? [], in: messages)
    }

    func apply(_ event: ChannelObservationEvent) throws -> Bool {
        if event.type == "deleted" {
            heldReplay = nil
            stopGrace()
            phase = .deleted
            observation = nil
            return true
        }
        if event.type == "snapshot", let snapshot = event.state {
            heldReplay = nil
            state = snapshot
            outbox?.received(snapshot.messages, in: id, api: api)
            historyGeneration = UUID()
            acknowledgedRead = snapshot.channel.seenThrough
            hasOlderMessages = (snapshot.messages.first?.sequence ?? 1) > 1
        } else if event.type != "resumed", heldReplay != nil {
            heldReplay?.append(event)
            return false
        } else if let previous = state {
            // `resumed` publishes the held replay with it, so each slice changes once.
            var events = heldReplay ?? []
            events.append(event)
            heldReplay = nil
            state = events.reduce(previous) { $0.applying($1) }
            outbox?.received(events.lazy.filter { $0.revision != nil }.compactMap(\.message), in: id, api: api)
        } else { throw ChannelAPIError.invalidEvent("pre-snapshot \(event.type)") }
        if event.type == "snapshot" || event.type == "resumed" {
            if !capturedUnread, let state {
                unreadAfter = state.channel.unreadAfter
                capturedUnread = true
            }
            stopGrace()
            phase = .connected
        }
        return false
    }

    /// Where a message the outbox sent landed, once this channel has it.
    func sequence(ofSent id: UUID) -> Int? {
        state?.messages.first { $0.sender == .user && UUID(uuidString: $0.id) == id }?.sequence
    }

    /// Shows a message the outbox sent before its event arrives.
    func mergeSent(_ message: ChannelMessage) {
        guard var current = state, phase != .deleted else { return }
        current.messages.removeAll { $0.id == message.id }
        current.messages = current.messages.merging([message])
        state = current
    }

    /// Observation skips assignments of an equal value, so each slice notifies only when it changes.
    private func syncSlices(_ state: ChannelState) {
        details = ChannelDetails(state.channel)
        roster = state.agents.map { agent in
            var identity = agent
            identity.status = nil
            return identity
        }
        var statuses: [String: ChannelAgent.Status] = [:]
        for agent in state.agents { statuses[agent.id] = agent.status }
        agentStatuses = statuses
        presence = state.presence
        if messages != state.messages {
            messages = state.messages
            artifactShares = ChannelArtifact.Share.shares(in: state.messages)
        }
        request = state.request
        requestSequence = state.channel.requestSequence
        tasks = state.channel.tasks
        artifacts = state.artifacts
        routines = state.routines
        syncBookmarks()
    }

    /// Which change failed, so an alert can say whether it was adding or removing the bookmark.
    public struct BookmarkFailure: Equatable, Identifiable, Sendable {
        public let id = UUID()
        public let sequence: Int
        public let isRemoval: Bool
        public let error: String
    }
}

@MainActor @Observable
public final class ChannelCatalogStore {
    public let api: ChannelAPI
    public private(set) var state: ChannelCatalog?
    /// A channel the outbox is sending to reads as read through its latest, since the server marks it
    /// read through the user's message once that lands.
    public var channels: [Channel] {
        let channels = state?.channels ?? []
        guard let sending = outbox?.sendingChannelIDs, !sending.isEmpty else { return channels }
        return channels.map { channel in
            var channel = channel
            if sending.contains(channel.id) { channel.read(through: channel.latestSequence) }
            return channel
        }
    }
    public var members: [ChannelAgent] { state?.members ?? [] }
    public private(set) var working: Set<String> = []
    public private(set) var isActive = true
    public private(set) var phase: ChannelCatalogPhase = .connecting
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
    /// The app's outbox. Setting it makes this catalog's server the one it delivers to.
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
    @ObservationIgnored private var reconcilingManagement = false
    @ObservationIgnored private let reconnectPolicy: ReconnectPolicy
    /// When the stream began failing without reporting it.
    @ObservationIgnored private var failingSince: Date?
    @ObservationIgnored private let now: () -> Date
    /// A refresh is waiting for the stream's next catalog or failure, so that failure reports at once.
    /// Internal and observed, so tests can wait for a refresh to reach the stream.
    private(set) var isRequested = false
    /// A refresh or management check is in flight. When it ends, the refreshes that joined it return.
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
    public init(api: ChannelAPI, reconnectPolicy: ReconnectPolicy = .init(), now: @escaping () -> Date = { .now },
                networkPath: NetworkPathSource = .system) {
        self.api = api
        self.reconnectPolicy = reconnectPolicy
        self.now = now
        self.networkPath = networkPath
    }
    deinit {
        stream?.cancel()
        pathWatch?.cancel()
    }

    public func channel(id: String) -> ChannelStore {
        if let existing = detailStores[id] { return existing }
        let store = ChannelStore(id: id, api: api, reconnectPolicy: reconnectPolicy)
        store.outbox = outbox
        detailStores[id] = store
        return store
    }

    /// A channel's store, only if something already asked for it.
    public func existingChannel(id: String) -> ChannelStore? { detailStores[id] }

    /// Reads a channel through `sequence` at once, ahead of the server's echo.
    func read(_ channelID: String, through sequence: Int) {
        guard let index = state?.channels.firstIndex(where: { $0.id == channelID }) else { return }
        state?.channels[index].read(through: sequence)
    }

    /// A refresh someone asked for, which joins one already in flight instead of returning early.
    /// While the stream is open it reopens the stream and returns with the fresh catalog that opens
    /// it, or reports the failure at once, since the caller waits on the outcome. Without a stream,
    /// as in the widget and share extensions, it fetches the catalog once.
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

    public func reconcileManagementWrite(channelId: String? = nil) async throws -> ChannelManagementReconciliation {
        guard !reconcilingManagement else {
            throw ChannelAPIError.invalidMessage("Another management change is being checked. Check again when it finishes.")
        }
        reconcilingManagement = true
        catalogGeneration = UUID()
        isFetching = true
        defer {
            reconcilingManagement = false
            isFetching = false
        }
        do {
            var catalog = try await api.catalog()
            var snapshot: ChannelState?
            if let channelId, catalog.channels.contains(where: { $0.id == channelId }) {
                do { snapshot = try await api.snapshot(channelId: channelId) }
                catch let failure as ChannelAPIError {
                    guard case .http(status: 404, message: _) = failure else { throw failure }
                    catalog = try await api.catalog()
                    guard !catalog.channels.contains(where: { $0.id == channelId }) else { throw failure }
                }
            }
            try Task.checkCancellation()
            if let channelId, let store = detailStores[channelId] {
                if let current = snapshot { snapshot = try store.reconcileManagementSnapshot(current) }
                else { store.reconcileManagementDeletion() }
            }
            applyCatalog(catalog)
            return .init(catalog: catalog, channelId: channelId, state: snapshot)
        } catch {
            phase = .failed(error)
            throw error
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
        working = Set(catalog.working)
        lastRefreshedAt = .now
        keepaliveRefreshDue = now().addingTimeInterval(Self.keepaliveRefreshInterval)
        failingSince = nil
        phase = .connected
        outbox?.catalogChanged(self, recovered: recovered)
        guard recovered else { return }
        for store in detailStores.values { store.retryPromptly() }
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
        var first: AsyncThrowingStream<SSEItem<ChannelCatalogEvent>, any Error>? = api.observeCatalog()
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
            isLive = true
            applyCatalog(catalog)
            settleRequest()
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
        settleRequest()
        isBackingOff = true
        return reconnectPolicy.delay(attempt: attempt)
    }

    private func reopen(token: UUID)
        -> (stream: AsyncThrowingStream<SSEItem<ChannelCatalogEvent>, any Error>, opened: Date)? {
        guard !Task.isCancelled, streamGeneration == token else { return nil }
        isBackingOff = false
        return (api.observeCatalog(), now())
    }

    /// Returns the refreshes waiting on the stream's next catalog or failure.
    private func settleRequest() {
        guard isRequested else { return }
        isRequested = false
        if !reconcilingManagement { isFetching = false }
    }

    /// Ends the stream's backoff early. An attempt already under way keeps going.
    private func retryPromptly() {
        guard isBackingOff else { return }
        openStream()
    }

    /// Coming back to the app ends the stream's backoff and every held channel's.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        guard active else { return }
        retryPromptly()
        for store in detailStores.values { store.retryPromptly() }
        outbox?.reload()
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
                outbox?.wake()
            }
        }
    }
}
