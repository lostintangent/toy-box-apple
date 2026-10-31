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

/// See Connections in docs/spec.md. A catalog has no stream to lose, so it's
/// `.connecting` only before its first outcome.
public enum ChannelCatalogPhase: Equatable, Sendable {
    case connecting
    /// The last refresh succeeded, or polls have failed for less than the grace.
    case connected
    /// A refresh someone asked for failed, or polls failed for the grace. Polling continues. It keeps
    /// the typed error, since a sign-in failure reports differently and the widget rethrows it.
    case failed(any Error)

    public var failure: (any Error)? {
        guard case .failed(let error) = self else { return nil }
        return error
    }
    public var message: String? { failure?.localizedDescription }

    /// A failure that repeats the current one is equal to it, so polls that keep failing the same
    /// way don't notify on each attempt.
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
    public private(set) var agentStatuses: [String: ChannelAgentStatus] = [:]
    public private(set) var presence: [String: ChannelAgentPresence] = [:]
    public private(set) var messages: [ChannelMessage] = []
    public private(set) var request: ChannelMessage?
    public private(set) var requestSequence: Int?
    public private(set) var tasks: [ChannelTask] = []
    public private(set) var artifacts: [ChannelArtifact] = []
    /// Who shared each artifact and when, by file ID, from the loaded messages.
    public private(set) var artifactShares: [String: ChannelArtifactShare] = [:]
    public private(set) var routines: [ChannelRoutine] = []

    /// Whether a snapshot has arrived, without observing anything that changes after it.
    public var isLoaded: Bool { details != nil }

    public private(set) var phase: ChannelConnectionPhase = .connecting
    public private(set) var unreadAfter: Int?
    public private(set) var isLoadingOlder = false
    public private(set) var hasOlderMessages = true
    public private(set) var isSending = false
    public private(set) var historyError: String?
    public private(set) var readError: String?
    public private(set) var sendAttempts: [ChannelSendAttempt] = []
    public private(set) var lastSendFailure: ChannelSendFailure?
    public private(set) var attemptPersistenceError: String?
    public private(set) var optimisticMessageIds: Set<String> = []
    /// Called with the channel's ID after the server accepts each send, retries included.
    @ObservationIgnored public var onSendConfirmed: (@MainActor (String) -> Void)?

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
    @ObservationIgnored private let reconnectPolicy: ReconnectPolicy
    @ObservationIgnored private let sendJournal: ChannelSendJournal?
    @ObservationIgnored private var attemptsRestored = false
    @ObservationIgnored private var persistenceTask: Task<Void, any Error>?

    /// `sleep` waits out each grace. Tests pass one they end instead of waiting.
    public init(id: String, api: ChannelAPI, reconnectPolicy: ReconnectPolicy = .init(),
                sendJournal: ChannelSendJournal? = .shared,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.id = id
        self.api = api
        self.reconnectPolicy = reconnectPolicy
        self.sendJournal = sendJournal
        self.sleep = sleep
    }

    deinit {
        observation?.cancel()
        grace?.cancel()
    }

    /// Starts the stream and the outbox restore at once, then keeps retrying until `disconnect()`.
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
        let restore = attemptsRestored ? nil : restoreSendAttemptsConcurrently()
        var first: AsyncThrowingStream<ChannelObservationEvent, any Error>? = openStream()
        observation = Task.detached(priority: Task.currentPriority) { [weak self] in
            // Events reconcile restored send attempts, so they wait for the restore.
            await restore?.value
            // Each stream lives only inside `do`, so leaving it for any reason closes the request.
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
        unreadAfter = state.flatMap { channelUnreadAfter($0.channel) }
        capturedUnread = state != nil && phase.isConnected
    }

    public func loadOlder() async {
        guard !isLoadingOlder, hasOlderMessages, let state,
              let first = state.messages.filter({ !optimisticMessageIds.contains($0.id) }).first else { return }
        if first.sequence <= 1 { hasOlderMessages = false; return }
        let historyToken = historyGeneration
        isLoadingOlder = true
        historyError = nil
        defer { isLoadingOlder = false }
        do {
            let page = try await api.history(channelId: id, before: first.sequence)
            guard historyGeneration == historyToken, phase != .deleted else { return }
            if var current = self.state {
                current.messages = mergeChannelMessages(current.messages, incoming: page.messages)
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

    @discardableResult
    public func post(id suppliedId: String? = nil, content: String,
                     attachments: [ChannelAttachment] = []) async throws -> ChannelSendResult {
        try await post(id: suppliedId, content: content, attachments: attachments, requiresConnection: true)
    }

    /// Persists before sending once, without starting or waiting for the channel's stream.
    @discardableResult
    public func postInBackground(id: String, content: String,
                                 attachments: [ChannelAttachment] = []) async throws -> ChannelSendResult {
        let result: ChannelSendResult
        do {
            result = try await post(id: id, content: content, attachments: attachments, requiresConnection: false)
        } catch {
            if sendAttempts.contains(where: { $0.id == id && $0.canRetry }) {
                try await persistSendAttempts()
            }
            throw error
        }
        if let persistenceTask {
            do { try await persistenceTask.value }
            catch { attemptPersistenceError = error.localizedDescription }
        }
        return result
    }

    private func post(id suppliedId: String?, content: String, attachments: [ChannelAttachment],
                      requiresConnection: Bool) async throws -> ChannelSendResult {
        try await restoreSendAttempts()
        guard !requiresConnection || (phase.isConnected && state != nil) else {
            throw ChannelAPIError.disconnected
        }
        if !requiresConnection, phase == .deleted {
            throw ChannelAPIError.http(status: 404, message: "Channel not found.")
        }
        let busyError = ChannelAPIError.invalidMessage("A message is already being sent.")
        guard !isSending || !requiresConnection else { throw busyError }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            throw ChannelAPIError.invalidMessage("A message or attachment is required.")
        }
        let id = suppliedId ?? UUID().uuidString
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf16.count <= 255 else {
            throw ChannelAPIError.invalidMessage("A send attempt requires a valid message ID.")
        }
        if let existing = sendAttempts.first(where: { $0.id == id }) {
            guard existing.content == trimmed, existing.attachments == attachments else {
                throw ChannelAPIError.invalidMessage("The attempted message changed. Send it as a new message.")
            }
            if existing.phase == .confirmed { return .alreadyAccepted(id: id) }
            guard !isSending else { throw busyError }
            return try await retrySend(id: id, requiresConnection: requiresConnection)
        }
        if let committed = state?.messages.first(where: { $0.id == id }) {
            guard committed.sender == .user, committed.content == .text(trimmed),
                  (committed.attachments ?? []) == attachments else {
                throw ChannelAPIError.invalidMessage("The message ID already belongs to different content. Send it as a new message.")
            }
            return .committed(committed)
        }
        let attempt = ChannelSendAttempt(id: id, content: trimmed, attachments: attachments,
                                         timestamp: Date.now.ISO8601Format(.init(includingFractionalSeconds: true)),
                                         phase: .sending)
        sendAttempts.append(attempt)
        optimisticMessageIds.insert(id)
        if isSending {
            recordSendFailure(id: id, phase: .notSent, error: busyError.localizedDescription)
            throw busyError
        }
        return try await deliver(attempt, requiresConnection: requiresConnection)
    }

    @discardableResult
    public func retrySend(id: String) async throws -> ChannelSendResult {
        try await retrySend(id: id, requiresConnection: true)
    }

    private func retrySend(id: String, requiresConnection: Bool) async throws -> ChannelSendResult {
        try await restoreSendAttempts()
        guard !requiresConnection || phase.isConnected else { throw ChannelAPIError.disconnected }
        guard !isSending else { throw ChannelAPIError.invalidMessage("A message is already being sent.") }
        guard let attempt = sendAttempts.first(where: { $0.id == id }), attempt.canRetry else {
            throw ChannelAPIError.invalidMessage("This send attempt cannot be repeated.")
        }
        updateAttempt(id: id, phase: .sending, error: nil)
        return try await deliver(attempt, requiresConnection: requiresConnection)
    }

    public func discardSendAttempt(id: String) async throws {
        guard let attempt = sendAttempts.first(where: { $0.id == id }), attempt.phase != .sending else {
            throw ChannelAPIError.invalidMessage("An in-flight send cannot be removed.")
        }
        let failure = lastSendFailure
        sendAttempts.removeAll { $0.id == id }
        optimisticMessageIds.remove(id)
        do {
            try await persistSendAttempts()
            if failure?.messageId == id, lastSendFailure?.id == failure?.id { lastSendFailure = nil }
        }
        catch {
            if !sendAttempts.contains(where: { $0.id == id }),
               state?.messages.contains(where: { $0.id == id }) != true {
                sendAttempts.append(attempt)
                sendAttempts.sort { $0.timestamp < $1.timestamp }
                optimisticMessageIds.insert(id)
            }
            throw error
        }
    }

    private func deliver(_ attempt: ChannelSendAttempt,
                         requiresConnection: Bool) async throws -> ChannelSendResult {
        let result = try await transmit(attempt, requiresConnection: requiresConnection)
        onSendConfirmed?(id)
        return result
    }

    private func transmit(_ attempt: ChannelSendAttempt,
                          requiresConnection: Bool) async throws -> ChannelSendResult {
        isSending = true
        lastSendFailure = nil
        defer { isSending = false }
        do {
            try await persistSendAttempts()
        } catch {
            recordSendFailure(id: attempt.id, phase: .notSent, error: error.localizedDescription)
            throw error
        }
        if let committed = state?.messages.first(where: { $0.id == attempt.id }) {
            reconcileSend(id: attempt.id)
            return .committed(committed)
        }
        guard (!requiresConnection || phase.isConnected), phase != .deleted else {
            let error: ChannelAPIError = !requiresConnection && phase == .deleted
                ? .http(status: 404, message: "Channel not found.") : .disconnected
            recordSendFailure(id: attempt.id, phase: .notSent, error: error.localizedDescription)
            saveAttemptsInBackground()
            throw error
        }
        do {
            let message = try await api.post(channelId: id, id: attempt.id, content: attempt.content,
                                             attachments: attempt.attachments)
            if var current = state, phase != .deleted {
                current.messages.removeAll { $0.id == attempt.id }
                current.messages = mergeChannelMessages(current.messages, incoming: [message])
                state = current
            }
            reconcileSend(id: attempt.id)
            return .committed(message)
        } catch ChannelAPIError.duplicateMessage {
            if let message = state?.messages.first(where: { $0.id == attempt.id }) {
                reconcileSend(id: attempt.id)
                return .committed(message)
            }
            updateAttempt(id: attempt.id, phase: .confirmed, error: nil)
            saveAttemptsInBackground()
            if requiresConnection { reconnect() }
            return .alreadyAccepted(id: attempt.id)
        } catch {
            if let message = state?.messages.first(where: { $0.id == attempt.id }) {
                reconcileSend(id: attempt.id)
                return .committed(message)
            }
            let definiteRejection: Bool
            if case ChannelAPIError.http(let status, _) = error {
                definiteRejection = (400..<500).contains(status) && status != 408
            } else if case ChannelAPIError.invalidMessage = error { definiteRejection = true }
            else { definiteRejection = false }
            recordSendFailure(id: attempt.id, phase: definiteRejection ? .notSent : .deliveryNotConfirmed,
                              error: error.localizedDescription)
            saveAttemptsInBackground()
            throw error
        }
    }

    private func recordSendFailure(id: String, phase: ChannelSendPhase, error: String) {
        updateAttempt(id: id, phase: phase, error: error)
        lastSendFailure = .init(id: UUID().uuidString, messageId: id, phase: phase, error: error)
    }

    private func updateAttempt(id: String, phase: ChannelSendPhase, error: String?) {
        guard let index = sendAttempts.firstIndex(where: { $0.id == id }) else { return }
        sendAttempts[index].phase = phase
        sendAttempts[index].error = error
    }

    private func reconcileSend(id: String) {
        if lastSendFailure?.messageId == id { lastSendFailure = nil }
        guard sendAttempts.contains(where: { $0.id == id }) else { return }
        sendAttempts.removeAll { $0.id == id }
        optimisticMessageIds.remove(id)
        saveAttemptsInBackground()
    }

    private func restoreSendAttempts() async throws {
        guard !attemptsRestored else { return }
        try await restoreSendAttempts(from: loadSendAttempts())
    }

    private func restoreSendAttemptsConcurrently() -> Task<Void, Never> {
        let load = loadSendAttempts()
        return Task { [weak self] in try? await self?.restoreSendAttempts(from: load) }
    }

    /// Reads the journal off the main actor, so a finished read restores without another hop.
    private func loadSendAttempts() -> Task<[ChannelSendAttempt], any Error> {
        let journal = sendJournal
        let server = api.baseURL
        let id = id
        return Task.detached(priority: Task.currentPriority) {
            try await journal?.load(server: server, channelId: id) ?? []
        }
    }

    private func restoreSendAttempts(from load: Task<[ChannelSendAttempt], any Error>) async throws {
        guard !attemptsRestored else { return }
        do {
            let restored = try await load.value
            guard !attemptsRestored else { return }
            sendAttempts = restored.map { attempt in
                var next = attempt
                if next.phase == .sending {
                    next.phase = .deliveryNotConfirmed
                    next.error = "The app closed before delivery was confirmed."
                }
                return next
            }
            optimisticMessageIds = Set(sendAttempts.map(\.id))
            attemptsRestored = true
            attemptPersistenceError = nil
        } catch {
            attemptPersistenceError = error.localizedDescription
            throw error
        }
    }

    private func persistSendAttempts() async throws {
        do {
            try await enqueuePersistence().value
            attemptPersistenceError = nil
        } catch {
            attemptPersistenceError = error.localizedDescription
            throw error
        }
    }

    private func saveAttemptsInBackground() {
        let save = enqueuePersistence()
        Task { [weak self] in
            do {
                try await save.value
                self?.attemptPersistenceError = nil
            } catch { self?.attemptPersistenceError = error.localizedDescription }
        }
    }

    private func enqueuePersistence() -> Task<Void, any Error> {
        let attempts = sendAttempts
        let journal = sendJournal
        let server = api.baseURL
        let channelId = id
        let predecessor = persistenceTask
        let task = Task<Void, any Error> {
            if let predecessor { _ = await predecessor.result }
            try await journal?.save(attempts, server: server, channelId: channelId)
        }
        persistenceTask = task
        return task
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
            historyGeneration = UUID()
            acknowledgedRead = snapshot.channel.seenThrough
            for attempt in sendAttempts where attempt.phase == .confirmed
                || snapshot.messages.contains(where: { $0.id == attempt.id }) {
                reconcileSend(id: attempt.id)
            }
            hasOlderMessages = (snapshot.messages.first?.sequence ?? 1) > 1
        } else if event.type != "resumed", heldReplay != nil {
            heldReplay?.append(event)
            return false
        } else if let previous = state {
            // `resumed` publishes the held replay with it, so each slice changes once.
            var events = heldReplay ?? []
            events.append(event)
            heldReplay = nil
            state = events.reduce(previous, reduceChannelState)
            for event in events {
                if let message = event.message, event.revision != nil { reconcileSend(id: message.id) }
            }
        } else { throw ChannelAPIError.invalidEvent("pre-snapshot \(event.type)") }
        if event.type == "snapshot" || event.type == "resumed" {
            if !capturedUnread, let state {
                unreadAfter = channelUnreadAfter(state.channel)
                capturedUnread = true
            }
            if event.type == "resumed" {
                for attempt in sendAttempts where attempt.phase == .confirmed { reconcileSend(id: attempt.id) }
            }
            stopGrace()
            phase = .connected
        }
        return false
    }

    /// Observation skips assignments of an equal value, so each slice notifies only when it changes.
    private func syncSlices(_ state: ChannelState) {
        details = ChannelDetails(state.channel)
        roster = state.agents.map { agent in
            var identity = agent
            identity.status = nil
            return identity
        }
        var statuses: [String: ChannelAgentStatus] = [:]
        for agent in state.agents { statuses[agent.id] = agent.status }
        agentStatuses = statuses
        presence = state.presence
        if messages != state.messages {
            messages = state.messages
            artifactShares = channelArtifactShares(state.messages)
        }
        request = state.request
        requestSequence = state.channel.requestSequence
        tasks = state.channel.tasks
        artifacts = state.artifacts
        routines = state.routines
    }
}

@MainActor @Observable
public final class ChannelCatalogStore {
    public let api: ChannelAPI
    public private(set) var state: ChannelCatalog?
    public var channels: [Channel] { state?.channels ?? [] }
    public var members: [ChannelMember] { state?.members ?? [] }
    public private(set) var working: Set<String> = []
    public private(set) var isActive = true
    public private(set) var phase: ChannelCatalogPhase = .connecting
    /// Whether a catalog has arrived. It stays true through failures, so the rows stay.
    public var isLoaded: Bool { state != nil }
    public private(set) var lastRefreshedAt: Date?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var pollingDelay: Task<Void, Never>?
    @ObservationIgnored private var pathWatch: Task<Void, Never>?
    @ObservationIgnored private let networkPath: NetworkPathSource
    @ObservationIgnored private var detailStores: [String: ChannelStore] = [:]
    /// Passed to every channel's store, so one place hears each send the server accepts.
    @ObservationIgnored public var onSendConfirmed: (@MainActor (String) -> Void)?
    @ObservationIgnored private var activePollingInterval: TimeInterval = 5
    @ObservationIgnored private var catalogGeneration = UUID()
    @ObservationIgnored private var reconcilingManagement = false
    @ObservationIgnored private let reconnectPolicy: ReconnectPolicy
    /// When the polls that are failing without reporting it began. Only polling counts.
    @ObservationIgnored private var failingSince: Date?
    @ObservationIgnored private let now: () -> Date
    /// Whether someone asked for the attempt in flight, so its failure reports at once. Internal and
    /// observed, so tests can wait for a requested refresh to join a poll.
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
    public var pollingInterval: TimeInterval { isActive ? activePollingInterval : 15 }

    /// `now` measures the grace. Tests pass a clock they move instead of waiting, and a network path
    /// they change.
    public init(api: ChannelAPI, reconnectPolicy: ReconnectPolicy = .init(), now: @escaping () -> Date = { .now },
                networkPath: NetworkPathSource = .system) {
        self.api = api
        self.reconnectPolicy = reconnectPolicy
        self.now = now
        self.networkPath = networkPath
    }
    deinit {
        polling?.cancel()
        pollingDelay?.cancel()
        pathWatch?.cancel()
    }

    public func channel(id: String) -> ChannelStore {
        if let existing = detailStores[id] { return existing }
        let store = ChannelStore(id: id, api: api, reconnectPolicy: reconnectPolicy)
        store.onSendConfirmed = { [weak self] in self?.onSendConfirmed?($0) }
        detailStores[id] = store
        return store
    }

    /// A channel's store, only if something already asked for it.
    public func existingChannel(id: String) -> ChannelStore? { detailStores[id] }

    /// A refresh someone asked for. It reports a failure at once, since the caller waits on the
    /// outcome, and joins an attempt already in flight instead of returning early. A poll that fails
    /// stays quiet and retries promptly until polls have failed for the grace, the way a channel
    /// stays `.connecting`, so a failed request on coming back to the app shows nothing.
    public func refresh() async {
        await refresh(prefetched: nil, requested: true)
    }

    private func refresh(prefetched: Task<ChannelCatalog, any Error>?, requested: Bool) async {
        if isFetching {
            prefetched?.cancel()
            guard requested else { return }
            isRequested = true
            return await withCheckedContinuation { joiners.append($0) }
        }
        let token = UUID()
        let started = now()
        catalogGeneration = token
        isRequested = requested
        isFetching = true
        defer { if catalogGeneration == token { isFetching = false } }
        do {
            let catalog = if let prefetched {
                try await withTaskCancellationHandler { try await prefetched.value }
                    onCancel: { prefetched.cancel() }
            } else {
                try await api.catalog()
            }
            guard !Task.isCancelled, catalogGeneration == token else { return }
            applyCatalog(catalog)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled,
                  catalogGeneration == token else { return }
            if !isRequested, phase.failure == nil {
                let since = failingSince ?? started
                failingSince = since
                guard now().timeIntervalSince(since) >= reconnectPolicy.grace else { return }
            }
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

    /// A poll that changes nothing announces only `lastRefreshedAt`, so the sidebar and its rows
    /// don't re-render every few seconds. `@Observable` skips assigning an equal value.
    /// When the server comes back, held channels waiting out a backoff try again at once.
    private func applyCatalog(_ catalog: ChannelCatalog) {
        let recovered = failingSince != nil || phase.failure != nil
        state = catalog
        working = Set(catalog.working)
        lastRefreshedAt = .now
        failingSince = nil
        phase = .connected
        guard recovered else { return }
        for store in detailStores.values { store.retryPromptly() }
    }

    /// Requests the first catalog immediately. A main-actor task would send it only on the main
    /// thread's first free turn, which at launch comes after the first window is built.
    public func startPolling(interval: TimeInterval = 5) {
        guard polling == nil else { return }
        activePollingInterval = interval
        failingSince = nil
        watchNetworkPath()
        let api = api
        let first = Task.detached(priority: Task.currentPriority) { try await api.catalog() }
        polling = Task { [weak self] in
            var prefetched: Task<ChannelCatalog, any Error>? = first
            defer { prefetched?.cancel() }
            while !Task.isCancelled {
                await self?.refresh(prefetched: prefetched, requested: false)
                prefetched = nil
                guard !Task.isCancelled, let delay = self?.nextPollDelay else { return }
                let pause = Task {
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                }
                self?.pollingDelay = pause
                await pause.value
                guard !Task.isCancelled else { return }
                self?.pollingDelay = nil
            }
        }
    }

    private var nextPollDelay: TimeInterval {
        failingSince != nil && phase.failure == nil ? reconnectPolicy.initialDelay : pollingInterval
    }

    /// Coming back to the app polls at once and ends every held channel's backoff.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        pollingDelay?.cancel()
        guard active else { return }
        for store in detailStores.values { store.retryPromptly() }
    }

    public func stopPolling() {
        polling?.cancel()
        polling = nil
        pollingDelay?.cancel()
        pollingDelay = nil
        pathWatch?.cancel()
        pathWatch = nil
    }

    /// While polling, a network that comes back or moves to another interface polls at once and
    /// gives every held channel that isn't connected a fresh attempt instead of its backoff.
    private func watchNetworkPath() {
        let paths = networkPath.paths()
        pathWatch = Task { [weak self] in
            var previous: NetworkPath?
            for await path in paths {
                defer { previous = path }
                guard path.isReturn(from: previous) else { continue }
                guard let self else { return }
                pollingDelay?.cancel()
                for store in detailStores.values { store.retryOnNewPath() }
            }
        }
    }
}
