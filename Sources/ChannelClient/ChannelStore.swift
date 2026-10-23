import ChannelKit
import Foundation
import Observation

public enum ChannelConnectionPhase: Equatable, Sendable {
    case idle
    case connecting
    case live
    case stale(message: String, retryAt: Date)
    case deleted

    public var isLive: Bool { self == .live }
    public var message: String? {
        guard case .stale(let message, _) = self else { return nil }
        return message
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

/// A channel's descriptive fields, without the counters and timestamps that every message moves.
public struct ChannelDetails: Equatable, Sendable {
    public var id: String
    public var name: String
    public var purpose: String?
    public var directory: String?
    public var model: ModelConfiguration
    public var preview: ChannelPreview?
    public var previewUrl: String?

    public init(_ channel: Channel) {
        id = channel.id
        name = channel.name
        purpose = channel.purpose
        directory = channel.directory
        model = channel.model
        preview = channel.preview
        previewUrl = channel.previewUrl
    }

    public var resolvedPreview: ChannelPreview? {
        preview ?? previewUrl.map { ChannelPreview(kind: "url", url: $0) }
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

    public private(set) var phase: ChannelConnectionPhase = .idle
    public private(set) var unreadAfter: Int?
    public private(set) var isLoadingOlder = false
    public private(set) var hasOlderMessages = true
    public private(set) var isSending = false
    public private(set) var sendError: String?
    public private(set) var historyError: String?
    public private(set) var readError: String?
    public private(set) var sendAttempts: [ChannelSendAttempt] = []
    public private(set) var lastSendFailure: ChannelSendFailure?
    public private(set) var attemptPersistenceError: String?
    public private(set) var optimisticMessageIds: Set<String> = []

    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var capturedUnread = false
    @ObservationIgnored private var historyGeneration = UUID()
    @ObservationIgnored private var markingRead = false
    @ObservationIgnored private var pendingRead = 0
    @ObservationIgnored private var acknowledgedRead = 0
    @ObservationIgnored private let reconnectPolicy: ReconnectPolicy
    @ObservationIgnored private let sendJournal: ChannelSendJournal?
    @ObservationIgnored private var attemptsRestored = false
    @ObservationIgnored private var persistenceTask: Task<Void, any Error>?

    public init(id: String, api: ChannelAPI, reconnectPolicy: ReconnectPolicy = .init(),
                sendJournal: ChannelSendJournal? = .shared) {
        self.id = id
        self.api = api
        self.reconnectPolicy = reconnectPolicy
        self.sendJournal = sendJournal
    }

    deinit { observation?.cancel() }

    /// Starts the stream and the outbox restore at once. Events are read off the main actor and
    /// each one is queued for it as soon as it decodes. Iterating the stream from the main actor
    /// would hop off and back even for a buffered event, which at launch held the first snapshot
    /// until after the window's first render.
    public func connect() {
        guard observation == nil, phase != .deleted else { return }
        generation = UUID()
        let token = generation
        phase = .connecting
        let restore = attemptsRestored ? nil : restoreSendAttemptsConcurrently()
        var first: AsyncThrowingStream<ChannelObservationEvent, any Error>? =
            api.observe(channelId: id, after: state?.revision)
        observation = Task.detached(priority: Task.currentPriority) { [weak self] in
            // Each stream lives only inside `do`, so leaving it for any reason closes the request.
            var next = first.take()
            var attempt = 0
            while true {
                do {
                    guard let events = next.take() else { return }
                    for try await event in events {
                        guard try await self?.receive(event, token: token, after: restore) == true else { return }
                        if event.type == "snapshot" || event.type == "resumed" { attempt = 0 }
                    }
                    throw ChannelAPIError.streamEnded
                } catch {
                    guard let delay = await self?.scheduleReconnect(after: error, attempt: attempt, token: token)
                    else { return }
                    attempt += 1
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                    next = await self?.resumeObservation(token: token)
                }
            }
        }
    }

    /// Applies an observed event once restored send attempts are known, so the event can
    /// reconcile them. Returns whether observation continues.
    private func receive(_ event: ChannelObservationEvent, token: UUID,
                         after restore: Task<Void, Never>?) async throws -> Bool {
        await restore?.value
        guard !Task.isCancelled, generation == token else { return false }
        return try !apply(event)
    }

    private func scheduleReconnect(after error: any Error, attempt: Int, token: UUID) -> TimeInterval? {
        guard !Task.isCancelled, generation == token else { return nil }
        let delay = reconnectPolicy.delay(attempt: attempt)
        phase = .stale(message: error.localizedDescription, retryAt: Date.now.addingTimeInterval(delay))
        return delay
    }

    private func resumeObservation(token: UUID) -> AsyncThrowingStream<ChannelObservationEvent, any Error>? {
        guard !Task.isCancelled, generation == token else { return nil }
        return api.observe(channelId: id, after: state?.revision)
    }

    public func disconnect() {
        generation = UUID()
        observation?.cancel()
        observation = nil
        if phase != .deleted { phase = .idle }
    }

    public func reconnect() {
        disconnect()
        connect()
    }

    fileprivate func reconcileManagementSnapshot(_ snapshot: ChannelState) throws -> ChannelState {
        if let state, state.revision > snapshot.revision { return state }
        let wasObserving = observation != nil
        disconnect()
        _ = try apply(.init(type: "snapshot", state: snapshot))
        if wasObserving { connect() }
        else { phase = .idle }
        return snapshot
    }

    fileprivate func reconcileManagementDeletion() {
        disconnect()
        historyGeneration = UUID()
        phase = .deleted
    }

    public func captureUnreadBoundary() {
        if let state {
            unreadAfter = channelUnreadAfter(state.channel)
            capturedUnread = true
        } else { capturedUnread = false }
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

    @discardableResult
    public func post(id suppliedId: String? = nil, content: String,
                     attachments: [ChannelAttachment] = []) async throws -> ChannelSendResult {
        try await restoreSendAttempts()
        guard phase.isLive, state != nil else { throw ChannelAPIError.disconnected }
        guard !isSending else { throw ChannelAPIError.invalidMessage("A message is already being sent.") }
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
            return try await retrySend(id: id)
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
        return try await deliver(attempt)
    }

    @discardableResult
    public func retrySend(id: String) async throws -> ChannelSendResult {
        try await restoreSendAttempts()
        guard phase.isLive else { throw ChannelAPIError.disconnected }
        guard !isSending else { throw ChannelAPIError.invalidMessage("A message is already being sent.") }
        guard let attempt = sendAttempts.first(where: { $0.id == id }), attempt.canRetry else {
            throw ChannelAPIError.invalidMessage("This send attempt cannot be repeated.")
        }
        updateAttempt(id: id, phase: .sending, error: nil)
        return try await deliver(attempt)
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

    private func deliver(_ attempt: ChannelSendAttempt) async throws -> ChannelSendResult {
        isSending = true
        sendError = nil
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
        guard phase.isLive else {
            recordSendFailure(id: attempt.id, phase: .notSent, error: ChannelAPIError.disconnected.localizedDescription)
            saveAttemptsInBackground()
            throw ChannelAPIError.disconnected
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
            reconnect()
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
        sendError = error
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
        sendError = nil
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

    public func markRead(through sequence: Int) async {
        guard phase.isLive, let channel = state?.channel else { return }
        pendingRead = max(pendingRead, min(sequence, channel.latestSequence))
        guard !markingRead, pendingRead > max(channel.seenThrough, acknowledgedRead) else { return }
        markingRead = true
        readError = nil
        defer { markingRead = false }
        while let current = state?.channel, pendingRead > max(current.seenThrough, acknowledgedRead), phase.isLive {
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
            phase = .deleted
            observation = nil
            return true
        }
        if event.type == "snapshot", let snapshot = event.state {
            state = snapshot
            historyGeneration = UUID()
            acknowledgedRead = snapshot.channel.seenThrough
            for attempt in sendAttempts where attempt.phase == .confirmed
                || snapshot.messages.contains(where: { $0.id == attempt.id }) {
                reconcileSend(id: attempt.id)
            }
            hasOlderMessages = (snapshot.messages.first?.sequence ?? 1) > 1
            if !capturedUnread {
                unreadAfter = channelUnreadAfter(snapshot.channel)
                capturedUnread = true
            }
        } else if let previous = state {
            state = reduceChannelState(previous, event)
            if let message = event.message, event.revision != nil {
                reconcileSend(id: message.id)
            }
        } else { throw ChannelAPIError.invalidEvent("pre-snapshot \(event.type)") }
        if event.type == "snapshot" || event.type == "resumed" {
            if event.type == "resumed" {
                for attempt in sendAttempts where attempt.phase == .confirmed { reconcileSend(id: attempt.id) }
            }
            phase = .live
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
    public private(set) var isLoading = false
    public private(set) var error: String?
    public private(set) var failure: (any Error)?
    public private(set) var lastRefreshedAt: Date?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var pollingDelay: Task<Void, Never>?
    @ObservationIgnored private var detailStores: [String: ChannelStore] = [:]
    @ObservationIgnored private var activePollingInterval: TimeInterval = 5
    @ObservationIgnored private var catalogGeneration = UUID()
    @ObservationIgnored private var reconcilingManagement = false
    public var pollingInterval: TimeInterval { isActive ? activePollingInterval : 15 }

    public init(api: ChannelAPI) { self.api = api }
    deinit {
        polling?.cancel()
        pollingDelay?.cancel()
    }

    public func channel(id: String) -> ChannelStore {
        if let existing = detailStores[id] { return existing }
        let store = ChannelStore(id: id, api: api)
        detailStores[id] = store
        return store
    }

    public func refresh() async {
        await refresh(prefetched: nil)
    }

    private func refresh(prefetched: Task<ChannelCatalog, any Error>?) async {
        guard !isLoading else { prefetched?.cancel(); return }
        let token = UUID()
        catalogGeneration = token
        isLoading = true
        defer { if catalogGeneration == token { isLoading = false } }
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
            self.error = error.localizedDescription
            failure = error
        }
    }

    public func reconcileManagementWrite(channelId: String? = nil) async throws -> ChannelManagementReconciliation {
        guard !reconcilingManagement else {
            throw ChannelAPIError.invalidMessage("Another management change is being checked. Check again when it finishes.")
        }
        reconcilingManagement = true
        catalogGeneration = UUID()
        isLoading = true
        defer {
            reconcilingManagement = false
            isLoading = false
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
            self.error = error.localizedDescription
            failure = error
            throw error
        }
    }

    private func applyCatalog(_ catalog: ChannelCatalog) {
        state = catalog
        working = Set(catalog.working)
        lastRefreshedAt = .now
        error = nil
        failure = nil
    }

    /// Requests the first catalog immediately. A main-actor task would send it only on the main
    /// thread's first free turn, which at launch comes after the first window is built.
    public func startPolling(interval: TimeInterval = 5) {
        guard polling == nil else { return }
        activePollingInterval = interval
        let api = api
        let first = Task.detached(priority: Task.currentPriority) { try await api.catalog() }
        polling = Task { [weak self] in
            var prefetched: Task<ChannelCatalog, any Error>? = first
            defer { prefetched?.cancel() }
            while !Task.isCancelled {
                await self?.refresh(prefetched: prefetched)
                prefetched = nil
                guard !Task.isCancelled, let delay = self?.pollingInterval else { return }
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

    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        pollingDelay?.cancel()
    }

    public func stopPolling() {
        polling?.cancel()
        polling = nil
        pollingDelay?.cancel()
        pollingDelay = nil
    }
}
