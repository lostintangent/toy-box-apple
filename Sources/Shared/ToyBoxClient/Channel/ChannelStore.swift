import ToyBoxKit
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

@MainActor @Observable
public final class ChannelStore {
    public let id: String
    public let api: ChannelAPI
    /// This channel on its server.
    public var target: ChannelTarget? { ChannelTarget(serverURL: api.baseURL.absoluteString, channelID: id) }
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
    /// How each agent appears by agent ID, from its status and whether the catalog lists it as
    /// working. The channel's stream doesn't carry presence.
    public private(set) var presence: [String: ChannelAgentPresence] = [:]
    /// The IDs of the agents running now, which the catalog store keeps current. It's empty while
    /// the catalog is unavailable, so nobody shows as working on a stale list.
    @ObservationIgnored var working: Set<String> = [] {
        didSet { if working != oldValue, let state { syncPresence(state) } }
    }
    public private(set) var messages: [ChannelMessage] = []
    public private(set) var request: ChannelMessage?
    public private(set) var requestSequence: Int?
    public private(set) var tasks: [ChannelTask] = []
    public private(set) var artifacts: [ChannelArtifact] = []
    /// Who shared each artifact and when, by file ID, from the loaded messages.
    public private(set) var artifactShares: [String: ChannelArtifact.Share] = [:]
    public private(set) var routines: [ChannelRoutine] = []
    /// The sequences of the messages the user bookmarked, oldest first, including any change still on
    /// its way to the server.
    public private(set) var bookmarks: [Int] = []
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
    /// The latest bookmark change that failed and was undone, until the next change or a dismissal.
    public private(set) var bookmarkFailure: BookmarkFailure?
    /// The app's outbox, which delivers every message sent through it. Set by the catalog store.
    @ObservationIgnored public internal(set) weak var outbox: ChannelOutbox?
    /// The messages the outbox still holds for this channel, Sending or Not sent, which the
    /// transcript shows below the server's.
    public var sending: [ChannelOutbox.Message] { outbox?.messages(in: id, on: api.baseURL) ?? [] }

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
    private(set) var heldReplay: [ChannelSubscriptionEvent]?
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
        var first: AsyncThrowingStream<ChannelSubscriptionEvent, any Error>? = openStream()
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
    private func receive(_ event: ChannelSubscriptionEvent, token: UUID) throws -> Bool {
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

    private func reopen(token: UUID) -> AsyncThrowingStream<ChannelSubscriptionEvent, any Error>? {
        guard !Task.isCancelled, generation == token else { return nil }
        isBackingOff = false
        return openStream()
    }

    /// Asks for everything after the published revision, or a snapshot when nothing is published.
    private func openStream() -> AsyncThrowingStream<ChannelSubscriptionEvent, any Error> {
        heldReplay = state == nil ? nil : []
        return api.subscribe(channelId: id, after: state?.revision, arrivals: arrivals)
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
    /// write fails. The store owns the write, so cancelling a caller doesn't interrupt it, and a later
    /// caller joins it rather than leaving its read for the next scroll. A failed write shows nothing
    /// and stays pending, so the next call sends it again.
    public func markRead(through sequence: Int) async {
        guard phase.isConnected, let channel = state?.channel else { return }
        pendingRead = max(pendingRead, min(sequence, channel.latestSequence))
        if readWrite == nil {
            guard pendingRead > max(channel.seenThrough, acknowledgedRead) else { return }
            readWrite = Task { await writeReads() }
        }
        await readWrite?.value
    }

    private func writeReads() async {
        defer { readWrite = nil }
        while let current = state?.channel, pendingRead > max(current.seenThrough, acknowledgedRead), phase.isConnected {
            let target = pendingRead
            guard let seen = try? await api.markRead(channelId: id, sequence: target) else { break }
            acknowledgedRead = max(acknowledgedRead, seen)
            if seen < target { break }
        }
    }

    /// Shows the change at once, then writes it into `state` when the server answers, so its echo
    /// changes nothing. A failed write leaves `state` as it was and reports `bookmarkFailure`.
    /// Bookmarking is idempotent, so a write makes one attempt and changing it again is the retry.
    /// Writes run in order, each sending its message's latest change, so the server ends where the
    /// user's last change left it.
    public func setBookmarked(_ bookmarked: Bool, sequence: Int) async {
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
        bookmarks = shown?.bookmarks ?? []
        bookmarkList = ChannelBookmark.list(bookmarks, in: messages)
    }

    func apply(_ event: ChannelSubscriptionEvent) throws -> Bool {
        // Presence comes from the catalog. A server that still streams it changes nothing here.
        if event.type == "presence" { return false }
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
        syncPresence(state)
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

    private func syncPresence(_ state: ChannelState) {
        var presence: [String: ChannelAgentPresence] = [:]
        for agent in state.agents { presence[agent.id] = agent.presence(isRunning: working.contains(agent.id)) }
        self.presence = presence
    }

    /// Which change failed, so an alert can say whether it was adding or removing the bookmark.
    public struct BookmarkFailure: Equatable, Identifiable, Sendable {
        public let id = UUID()
        public let sequence: Int
        public let isRemoval: Bool
        public let error: String
    }
}
