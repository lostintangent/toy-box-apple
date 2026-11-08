import ChannelKit
import Foundation
import Observation
import os

/// Every message the user sends, from any entry point, until the server confirms it. One per app,
/// made at launch. The catalog store for the current server delivers that server's messages, with
/// no channel window or stream needed. See Sending in docs/spec.md.
@MainActor @Observable
public final class ChannelOutbox {
    public struct Message: Codable, Equatable, Identifiable, Sendable {
        /// Reused by every attempt, so the server never posts it twice.
        public let id: UUID
        /// The normalized server URL it goes to.
        public let server: String
        public let channelID: String
        public let text: String
        public let attachments: [ChannelAttachment]
        /// The request it answers.
        public let request: Int?
        public let sentAt: Date
        public internal(set) var state: State

        /// The row a transcript shows until the server's message replaces it.
        public var message: ChannelMessage {
            .init(id: id.uuidString, sequence: 0,
                  timestamp: sentAt.ISO8601Format(.init(includingFractionalSeconds: true)),
                  sender: .user, content: .text(text), attachments: attachments.isEmpty ? nil : attachments)
        }
    }

    public enum State: String, Codable, Equatable, Sendable {
        case sending
        /// The outbox stopped trying: the server refused it, or kept failing for the retry window.
        /// Retry sends it again under the same ID, and Delete withdraws it.
        case notSent
    }

    /// Where each message is saved as its own file.
    public let folder: URL
    /// Every message not yet confirmed, on every server, in the order they were sent.
    private(set) var queue: [Message] = []
    /// The requests answered by a confirmed message, by server and channel, until the catalog stops
    /// listing them as waiting.
    private(set) var answered: [Destination: Set<Int>] = [:]
    /// The server whose catalog delivers, so rows and the waiting rule read only its messages.
    public private(set) var server: String?
    /// True while a message to the current server is still sending, or a confirmed one is still
    /// marking its channel read, so the phone's app delegate holds background time.
    public private(set) var isDelivering = false
    /// The saved messages have been read, so delivery can start in order.
    private(set) var isLoaded = false

    @ObservationIgnored private weak var catalog: ChannelCatalogStore?
    /// Each channel's delivery, one message at a time.
    @ObservationIgnored private var lines: [String: Task<Void, Never>] = [:]
    /// The channels whose line waits for the server to be reachable again, which `wake()` cuts short.
    @ObservationIgnored private var waiting: Set<String> = []
    /// Confirmed or withdrawn this run, so a scan that read a file before its removal doesn't bring
    /// the message back.
    @ObservationIgnored private var removed: Set<UUID> = []
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private let sendsOnce: Bool
    @ObservationIgnored private var writes: Task<Void, Never>?
    @ObservationIgnored private var scanning: Task<Void, Never>?
    @ObservationIgnored private let retryWindow: TimeInterval
    @ObservationIgnored private let reconnectPolicy: ReconnectPolicy
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// The Mac's folder, beside its drafts. The phone passes one in its shared app group instead.
    public static var defaultFolder: URL { .savedWriting().appending(path: "Sending", directoryHint: .isDirectory) }

    /// `sendsOnce` is for the share extension, which ends before it could retry. Its outbox leaves
    /// the folder's other messages to the app, and each send makes one attempt before it returns.
    /// Whatever that leaves Sending, the app sends at its next launch.
    public convenience init(folder: URL = ChannelOutbox.defaultFolder, sendsOnce: Bool = false) {
        self.init(folder: folder, retryWindow: 120, sendsOnce: sendsOnce)
    }

    /// `now` and `sleep` time retries. Tests pass a clock they move instead of waiting.
    init(folder: URL, retryWindow: TimeInterval, reconnectPolicy: ReconnectPolicy = .init(),
         now: @escaping () -> Date = { .now },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         sendsOnce: Bool = false) {
        self.folder = folder
        self.retryWindow = retryWindow
        self.reconnectPolicy = reconnectPolicy
        self.now = now
        self.sleep = sleep
        self.sendsOnce = sendsOnce
        // Without a scan the outbox never loads, so it starts no lines.
        if !sendsOnce { scan() }
    }

    // MARK: Sending

    /// Shows the message in its channel at once and returns once it's saved. Never throws, and if
    /// saving fails the message still sends from memory. `answering` is the request the caller acted
    /// on. Without one, it's the request waiting in that channel now.
    @discardableResult
    public func send(_ text: String, attachments: [ChannelAttachment] = [], to channelID: String, on server: URL,
                     answering request: Int? = nil) async -> UUID {
        let destination = Destination(server: Self.key(server), channelID: channelID)
        let message = Message(id: UUID(), server: destination.server, channelID: channelID,
                              text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                              attachments: attachments,
                              request: request ?? waitingRequest(at: destination), sentAt: now(), state: .sending)
        queue.append(message)
        // The row shows at once, and delivery starts once the message is saved.
        await save(message).value
        changed()
        if sendsOnce { await attempt(message) }
        return message.id
    }

    /// The transcript's own rows for a channel on the current server: Sending or Not sent, in order.
    public func messages(in channelID: String) -> [Message] {
        guard let server else { return [] }
        return queue.filter { $0.server == server && $0.channelID == channelID }
    }

    func message(_ id: UUID) -> Message? { queue.first { $0.id == id } }

    /// The channels on the current server with a message Sending.
    var sendingChannelIDs: Set<String> {
        Set(queue.lazy.filter { $0.server == self.server && $0.state == .sending }.map(\.channelID))
    }

    /// Puts a Not sent message back in line under the same ID.
    public func sendAgain(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }), queue[index].state != .sending else { return }
        queue[index].state = .sending
        save(queue[index])
        changed()
    }

    /// Takes a Not sent message out, for Delete.
    public func withdraw(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }), queue[index].state != .sending else { return }
        queue.remove(at: index)
        removed.insert(id)
        delete(id)
        changed()
    }

    // MARK: The waiting rule

    /// Whether a request reads as answered outside its channel: an answer is sending, or one was
    /// confirmed and the catalog still lists the request. A Not sent answer doesn't count, so the
    /// request comes back where it was.
    public func answers(_ request: Int, in channelID: String) -> Bool {
        guard let server else { return false }
        let destination = Destination(server: server, channelID: channelID)
        return answered[destination]?.contains(request) == true || queue.contains {
            $0.server == server && $0.channelID == channelID && $0.request == request && $0.state == .sending
        }
    }

    // MARK: The catalog store's signals

    /// The catalog store for the current server delivers its messages. Another server's wait.
    func attach(_ catalog: ChannelCatalogStore) {
        guard self.catalog !== catalog else { return }
        restart(lines.keys)
        self.catalog = catalog
        server = Self.key(catalog.api.baseURL)
        catalogChanged(catalog, recovered: false)
        changed()
    }

    func detach(_ catalog: ChannelCatalogStore) {
        guard self.catalog === catalog else { return }
        restart(lines.keys)
        self.catalog = nil
        server = nil
        changed()
    }

    /// Reads the folder again for messages another process saved, such as the share extension.
    func reload() {
        scan()
        wake()
    }

    /// The server may be reachable again, so every line waiting for it tries now.
    func wake() {
        restart(waiting)
        changed()
    }

    /// Each catalog prunes answers the catalog no longer lists as waiting, and drops the messages of
    /// channels it no longer lists. One that follows a failure means the server is back.
    func catalogChanged(_ store: ChannelCatalogStore, recovered: Bool) {
        guard store === catalog, let server, let catalog = store.state else { return }
        if recovered { wake() }
        let channels = Dictionary(catalog.channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (destination, requests) in answered where destination.server == server {
            // A catalog older than the request can't say it was answered.
            let kept = requests.filter { request in
                guard let channel = channels[destination.channelID] else { return false }
                return channel.requestSequence == request || channel.latestSequence < request
            }
            answered[destination] = kept.isEmpty ? nil : kept
        }
        let gone = queue.filter { $0.server == server && channels[$0.channelID] == nil }.map(\.id)
        guard !gone.isEmpty else { return }
        for id in gone { drop(id) }
        changed()
    }

    /// A channel's snapshot or replay arrived with these messages, so any of ours among them, Sending
    /// or Not sent, is confirmed.
    func received(_ messages: some Sequence<ChannelMessage>, in channelID: String, on server: URL) {
        let key = Self.key(server)
        guard queue.contains(where: { $0.server == key && $0.channelID == channelID }) else { return }
        let ids = Set(messages.lazy.filter { $0.sender == .user }.compactMap { UUID(uuidString: $0.id) })
        let echoed = queue.filter { $0.server == key && $0.channelID == channelID && ids.contains($0.id) }
        for message in echoed { confirm(message.id) }
    }

    // MARK: Delivery

    /// Recomputes what depends on the queue and starts a line for each channel with a message to send.
    private func changed() {
        let delivering = reads > 0
            || server.map { server in queue.contains { $0.server == server && $0.state == .sending } } ?? false
        if isDelivering != delivering { isDelivering = delivering }
        guard isLoaded, let catalog, let server else { return }
        let api = catalog.api
        for channelID in sendingChannelIDs where lines[channelID] == nil {
            lines[channelID] = Task { [weak self] in await self?.deliver(in: channelID, server: server, api: api) }
        }
    }

    /// Ends these channels' lines, so `changed()` starts each again from its next message.
    private func restart(_ channelIDs: some Sequence<String>) {
        for channelID in Array(channelIDs) {
            lines.removeValue(forKey: channelID)?.cancel()
            waiting.remove(channelID)
        }
    }

    /// Sends a channel's messages one at a time, oldest first. A Not sent message steps out of line.
    private func deliver(in channelID: String, server: String, api: ChannelAPI) async {
        while !Task.isCancelled, let next = queue.first(where: {
            $0.server == server && $0.channelID == channelID && $0.state == .sending
        }) {
            await deliver(next, api: api)
        }
        if !Task.isCancelled { lines[channelID] = nil }
    }

    /// Tries until the server confirms or refuses the message, or it stops being Sending. Trouble
    /// retries within the window, and a server Toy Box can't reach gets as long as it takes.
    private func deliver(_ message: Message, api: ChannelAPI) async {
        var troubleSince: Date?
        var attempt = 0
        while !Task.isCancelled, self.message(message.id)?.state == .sending {
            let started = now()
            let outcome = await post(message, api: api)
            guard !Task.isCancelled, self.message(message.id)?.state == .sending else { return }
            let delay = reconnectPolicy.delay(attempt: attempt)
            attempt += 1
            switch outcome {
            case .accepted(let sent):
                confirm(message.id, merging: sent)
                return
            case .rejected:
                return stop(message.id)
            case .unreachable:
                troubleSince = nil
                waiting.insert(message.channelID)
            case .trouble:
                let since = troubleSince ?? started
                troubleSince = since
                guard now().timeIntervalSince(since) + delay <= retryWindow else { return stop(message.id) }
            }
            try? await sleep(delay)
            if !Task.isCancelled { waiting.remove(message.channelID) }
        }
    }

    /// The share extension's one attempt, which returns once its outcome is saved and its channel
    /// marked read. It gives up after 10 seconds without hearing from the server, so a sleeping
    /// server leaves the message to the app instead of keeping the sheet on Sending for a minute.
    private func attempt(_ message: Message) async {
        guard let catalog else { return }
        switch await post(message, api: catalog.api, timeout: 10) {
        case .accepted(let sent): await confirm(message.id, merging: sent)?.value
        case .rejected: stop(message.id)
        case .unreachable, .trouble: break
        }
        await writes?.value
    }

    private func post(_ message: Message, api: ChannelAPI, timeout: TimeInterval? = nil) async -> Outcome {
        let isLive = catalog?.isLive ?? false
        do {
            var request = try api.messageRequest(channelId: message.channelID, id: message.id.uuidString,
                                                 content: message.text, attachments: message.attachments)
            if let timeout { request.timeoutInterval = timeout }
            let (data, response) = try await api.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return .trouble }
            let outcome = Outcome(response, data: data, isLive: isLive)
            if case .accepted = outcome { return outcome }
            let failure = ChannelAPI.failure(status: response.statusCode, data: data)
            Self.logger.info("Sending got \(response.statusCode): \(failure.localizedDescription)")
            return outcome
        } catch {
            Self.logger.info("Sending failed: \(error.localizedDescription)")
            return Outcome(error, isLive: isLive)
        }
    }

    /// Returns the channel's mark read, if it makes one.
    @discardableResult
    private func confirm(_ id: UUID, merging sent: ChannelMessage? = nil) -> Task<Void, Never>? {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return nil }
        let message = queue.remove(at: index)
        removed.insert(id)
        delete(id)
        let destination = Destination(server: message.server, channelID: message.channelID)
        if let request = message.request { answered[destination, default: []].insert(request) }
        var read: Task<Void, Never>?
        if message.server == server, let catalog {
            let store = catalog.existingChannel(id: message.channelID)
            if let sent { store?.mergeSent(sent) }
            // The user's own message never leaves its channel unread. A 409 brings no sequence, so it
            // marks nothing unless the open channel already has the message.
            if let through = sent?.sequence ?? store?.sequence(ofSent: id) {
                catalog.read(message.channelID, through: through)
                read = markRead(message.channelID, through: through, api: catalog.api)
            }
            catalog.onSendConfirmed?(message.channelID)
        }
        changed()
        return read
    }

    /// One attempt, logging a failure. It counts as delivering, so the phone's background time covers it.
    private func markRead(_ channelID: String, through sequence: Int, api: ChannelAPI) -> Task<Void, Never> {
        reads += 1
        return Task {
            do { _ = try await api.markRead(channelId: channelID, sequence: sequence) }
            catch { Self.logger.info("Could not mark a sent message read: \(error.localizedDescription)") }
            reads -= 1
            changed()
        }
    }

    private func stop(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].state = .notSent
        save(queue[index])
        changed()
    }

    private func drop(_ id: UUID) {
        queue.removeAll { $0.id == id }
        removed.insert(id)
        delete(id)
    }

    /// The request waiting in a channel on the current server: the open channel's, otherwise the
    /// catalog's.
    private func waitingRequest(at destination: Destination) -> Int? {
        guard let catalog, destination.server == server else { return nil }
        if let store = catalog.existingChannel(id: destination.channelID), store.isLoaded { return store.requestSequence }
        return catalog.channels.first { $0.id == destination.channelID }?.requestSequence
    }

    static func key(_ server: URL) -> String {
        ChannelWaitingRequest.normalizedServer(server.absoluteString) ?? server.absoluteString
    }

    // MARK: Files

    nonisolated private static let logger = Logger(subsystem: "dev.toybox", category: "Outbox")

    /// Reads every saved message, then starts delivery. Messages already known stay as they are.
    private func scan() {
        let folder = folder
        let previous = scanning
        let read = Task.detached(priority: .userInitiated) { Self.read(folder) }
        scanning = Task { [weak self] in
            await previous?.value
            let found = await read.value
            self?.merge(found)
        }
    }

    private func merge(_ found: [Message]) {
        let known = Set(queue.map(\.id)).union(removed)
        let added = found.filter { !known.contains($0.id) }
        if !added.isEmpty {
            queue.append(contentsOf: added)
            queue.sort { $0.sentAt < $1.sentAt }
        }
        isLoaded = true
        changed()
    }

    nonisolated private static func read(_ folder: URL) -> [Message] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            do { return try decoder.decode(Message.self, from: Data(contentsOf: file)) }
            catch {
                Self.logger.error("Could not read a saved message: \(error.localizedDescription)")
                return nil
            }
        }
    }

    @discardableResult
    private func save(_ message: Message) -> Task<Void, Never> {
        let folder = folder
        return write { try Self.write(message, in: folder) }
    }

    private func delete(_ id: UUID) {
        let file = folder.appending(path: id.uuidString + ".json")
        write {
            do { try FileManager.default.removeItem(at: file) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
        }
    }

    /// Runs file changes one at a time, in the order they were made, off the main actor.
    @discardableResult
    private func write(_ change: @escaping @Sendable () throws -> Void) -> Task<Void, Never> {
        let previous = writes
        let task = Task.detached(priority: .userInitiated) {
            await previous?.value
            do { try change() }
            catch { Self.logger.error("Could not save the outbox: \(error.localizedDescription)") }
        }
        writes = task
        return task
    }

    nonisolated private static func write(_ message: Message, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appending(path: message.id.uuidString + ".json")
        try JSONEncoder().encode(message).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Waits for every file change made so far. Tests read the folder after it.
    func settled() async {
        await scanning?.value
        await writes?.value
    }
}

extension ChannelOutbox {
    struct Destination: Hashable, Sendable {
        let server: String
        let channelID: String
    }

    /// What one attempt's answer means for the message.
    enum Outcome: Equatable, Sendable {
        /// A 2xx, with the message when it decodes, or a 409 for an ID the server already has.
        case accepted(ChannelMessage?)
        /// Toy Box can't reach the server, so the message waits for a reconnect, however long.
        case unreachable
        /// The server has trouble, so the message retries within the window.
        case trouble
        /// The server refused it, so the message stops as Not sent.
        case rejected

        /// A gateway answers these for a server that isn't running, as Tailscale Serve and Cloudflare
        /// Tunnel do while the Mac sleeps. With the catalog connected, the server itself is in trouble.
        static let gatewayStatuses: Set<Int> = [502, 503, 504, 530]

        static let unreachableErrors: Set<URLError.Code> = [
            .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive, .cancelled,
        ]

        init(_ response: HTTPURLResponse, data: Data, isLive: Bool) {
            switch response.statusCode {
            case 200..<300: self = .accepted(ChannelAPI.sentMessage(in: data))
            case 409: self = .accepted(nil)
            case let status where Self.gatewayStatuses.contains(status): self = isLive ? .trouble : .unreachable
            case 408, 429, 500...: self = .trouble
            case 400..<500: self = .rejected
            default: self = .trouble
            }
        }

        /// A timeout is a weak signal, like a gateway error, unless the catalog is connected.
        init(_ error: any Error, isLive: Bool) {
            let code = (error as? URLError)?.code
            if let code, Self.unreachableErrors.contains(code) || code == .timedOut && !isLive {
                self = .unreachable
            } else {
                self = .trouble
            }
        }
    }
}
