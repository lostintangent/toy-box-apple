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

@MainActor @Observable
public final class ChannelStore {
    public let id: String
    public let api: ChannelAPI
    public private(set) var state: ChannelState?
    public private(set) var phase: ChannelConnectionPhase = .idle
    public private(set) var unreadAfter: Int?
    public private(set) var isLoadingOlder = false
    public private(set) var hasOlderMessages = true
    public private(set) var isSending = false
    public private(set) var sendError: String?
    public private(set) var historyError: String?
    public private(set) var readError: String?
    public private(set) var optimisticMessageIds: Set<String> = []

    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var capturedUnread = false
    @ObservationIgnored private var historyGeneration = UUID()
    @ObservationIgnored private var markingRead = false
    @ObservationIgnored private var pendingRead = 0
    @ObservationIgnored private var acknowledgedRead = 0
    @ObservationIgnored private let reconnectPolicy: ReconnectPolicy

    public init(id: String, api: ChannelAPI, reconnectPolicy: ReconnectPolicy = .init()) {
        self.id = id
        self.api = api
        self.reconnectPolicy = reconnectPolicy
    }

    deinit { observation?.cancel() }

    public func connect() {
        guard observation == nil, phase != .deleted else { return }
        generation = UUID()
        let token = generation
        let api = api
        let id = id
        let policy = reconnectPolicy
        phase = .connecting
        observation = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled && self?.generation == token {
                do {
                    for try await event in api.observe(channelId: id, after: self?.state?.revision) {
                        guard !Task.isCancelled, self?.generation == token else { return }
                        guard let terminal = try self?.apply(event) else { return }
                        if terminal { return }
                        if event.type == "snapshot" || event.type == "resumed" { attempt = 0 }
                    }
                    throw ChannelAPIError.streamEnded
                } catch {
                    guard !Task.isCancelled, self?.generation == token else { return }
                    let delay = policy.delay(attempt: attempt)
                    attempt += 1
                    self?.phase = .stale(message: error.localizedDescription,
                                         retryAt: Date.now.addingTimeInterval(delay))
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                }
            }
        }
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
    public func post(content: String, attachments: [ChannelAttachment] = []) async throws -> ChannelMessage {
        guard phase.isLive, var current = state else { throw ChannelAPIError.disconnected }
        guard !isSending else { throw ChannelAPIError.invalidMessage("A message is already being sent.") }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            throw ChannelAPIError.invalidMessage("A message or attachment is required.")
        }
        let id = UUID().uuidString
        let optimistic = ChannelMessage(id: id, sequence: 0,
                                        timestamp: Date.now.ISO8601Format(.init(includingFractionalSeconds: true)),
                                        sender: .user, content: .text(trimmed),
                                        attachments: attachments.isEmpty ? nil : attachments)
        current = reduceChannelState(current, .init(type: "message", message: optimistic))
        state = current
        optimisticMessageIds.insert(id)
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            let message = try await api.post(channelId: self.id, id: id, content: trimmed, attachments: attachments)
            if var current = state, phase != .deleted {
                current.messages.removeAll { $0.id == id }
                current.messages = mergeChannelMessages(current.messages, incoming: [message])
                state = current
            }
            optimisticMessageIds.remove(id)
            return message
        } catch {
            if optimisticMessageIds.remove(id) != nil { state?.messages.removeAll { $0.id == id } }
            sendError = error.localizedDescription
            throw error
        }
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

    private func apply(_ event: ChannelObservationEvent) throws -> Bool {
        if event.type == "deleted" {
            phase = .deleted
            observation = nil
            return true
        }
        if event.type == "snapshot", let snapshot = event.state {
            state = snapshot
            historyGeneration = UUID()
            acknowledgedRead = snapshot.channel.seenThrough
            optimisticMessageIds.removeAll()
            hasOlderMessages = (snapshot.messages.first?.sequence ?? 1) > 1
            if !capturedUnread {
                unreadAfter = channelUnreadAfter(snapshot.channel)
                capturedUnread = true
            }
        } else if let previous = state {
            state = reduceChannelState(previous, event)
            if let message = event.message, event.revision != nil {
                optimisticMessageIds.remove(message.id)
            }
        } else { throw ChannelAPIError.invalidEvent("pre-snapshot \(event.type)") }
        if event.type == "snapshot" || event.type == "resumed" {
            phase = .live
        }
        return false
    }
}

@MainActor @Observable
public final class ChannelCatalogStore {
    public let api: ChannelAPI
    public private(set) var channels: [Channel] = []
    public private(set) var members: [ChannelMember] = []
    public private(set) var isLoading = false
    public private(set) var error: String?
    public private(set) var lastRefreshedAt: Date?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var detailStores: [String: ChannelStore] = [:]

    public init(api: ChannelAPI) { self.api = api }
    deinit { polling?.cancel() }

    public func channel(id: String) -> ChannelStore {
        if let existing = detailStores[id] { return existing }
        let store = ChannelStore(id: id, api: api)
        detailStores[id] = store
        return store
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let catalog = try await api.catalog()
            channels = catalog.channels
            members = catalog.members
            lastRefreshedAt = .now
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    public func startPolling(interval: TimeInterval = 15) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
            }
        }
    }

    public func stopPolling() {
        polling?.cancel()
        polling = nil
    }
}
