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
    @ObservationIgnored private var lines: [String: Line] = [:]
    @ObservationIgnored private var pauses: [UUID: Pause] = [:]
    /// Confirmed or withdrawn this run, so a scan that read a file before its removal doesn't bring
    /// the message back.
    @ObservationIgnored private var removed: Set<UUID> = []
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private let uploads: (any Uploads)?
    @ObservationIgnored private let handsOff: Bool
    /// Messages iOS is uploading, so a second hand-off skips them.
    @ObservationIgnored private var uploading: Set<UUID> = []
    /// What the app delegate runs once a session iOS woke it for has reported every upload, by session.
    @ObservationIgnored private var completions: [String: () -> Void] = [:]
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var writes: Task<Void, Never>?
    @ObservationIgnored private var scanning: Task<Void, Never>?
    @ObservationIgnored private let retryWindow: TimeInterval
    @ObservationIgnored private let reconnectPolicy: ReconnectPolicy
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// The Mac's folder, beside its drafts. The phone passes one in its shared app group instead.
    public static var defaultFolder: URL { .savedWriting().appending(path: "Sending", directoryHint: .isDirectory) }

    /// `background` hands sends to iOS on the phone. See `handOff()`.
    public convenience init(folder: URL = ChannelOutbox.defaultFolder, background: Background? = nil) {
        self.init(folder: folder, retryWindow: 120,
                  uploads: background.map { BackgroundUploads($0, folder: folder) },
                  handsOff: background?.handsOff ?? false)
    }

    /// `now` and `sleep` time retries. Tests pass a clock they move instead of waiting.
    init(folder: URL, retryWindow: TimeInterval, reconnectPolicy: ReconnectPolicy = .init(),
         now: @escaping () -> Date = { .now },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         uploads: (any Uploads)? = nil, handsOff: Bool = false) {
        self.folder = folder
        self.retryWindow = retryWindow
        self.reconnectPolicy = reconnectPolicy
        self.now = now
        self.sleep = sleep
        self.uploads = uploads
        self.handsOff = handsOff
        // An outbox that hands off sends only its own messages, and leaves the rest to the app.
        if handsOff { isLoaded = true } else { scan() }
        if let uploads { listen(to: uploads) }
    }

    // MARK: Sending

    /// Shows the message in its channel at once and returns once it's saved. Never throws, and if
    /// saving fails the message still sends from memory. `answering` is the request the caller acted
    /// on. Without one, it's the request waiting in that channel now. Sending an ID that's Not sent
    /// sends it again.
    @discardableResult
    public func send(_ text: String, images: [ComposerImage] = [], to channelID: String, on server: URL,
                     answering request: Int? = nil, id: UUID = UUID()) async -> UUID {
        await send(text, attachments: images.map(\.attachment), to: channelID, on: server, answering: request, id: id)
    }

    /// Sends attachments already encoded, as the share sheet's are.
    @discardableResult
    public func send(_ text: String, attachments: [ChannelAttachment], to channelID: String, on server: URL,
                     answering request: Int? = nil, id: UUID = UUID()) async -> UUID {
        if let existing = queue.first(where: { $0.id == id }) {
            if existing.state != .sending { sendAgain(id) }
            return id
        }
        let destination = Destination(server: Self.key(server), channelID: channelID)
        let message = Message(id: id, server: destination.server, channelID: channelID,
                              text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                              attachments: attachments,
                              request: request ?? waitingRequest(at: destination), sentAt: now(), state: .sending)
        removed.remove(id)
        queue.append(message)
        // The row shows at once, and delivery starts once the message is saved.
        await save(message).value
        changed()
        // The extension ends right after, so its upload must have started.
        if handsOff { await writes?.value }
        return id
    }

    /// The transcript's own rows for a channel on the current server: Sending or Not sent, in order.
    public func messages(in channelID: String) -> [Message] {
        guard let server else { return [] }
        return queue.filter { $0.server == server && $0.channelID == channelID }
    }

    public func message(_ id: UUID) -> Message? { queue.first { $0.id == id } }

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

    /// Whether any answer to a request is in the outbox, Sending or Not sent. The channel hides the
    /// request's choices meanwhile, since a Not sent answer sits right below with Send Again.
    public func holdsAnswer(to request: Int, in channelID: String) -> Bool {
        guard let server else { return false }
        return queue.contains { $0.server == server && $0.channelID == channelID && $0.request == request }
    }

    // MARK: The catalog store's signals

    /// The catalog store for the current server delivers its messages. Another server's wait.
    func attach(_ catalog: ChannelCatalogStore) {
        guard self.catalog !== catalog else { return }
        for line in lines.values { line.task.cancel() }
        lines = [:]
        self.catalog = catalog
        server = Self.key(catalog.api.baseURL)
        catalogChanged(catalog, recovered: false)
        changed()
    }

    func detach(_ catalog: ChannelCatalogStore) {
        guard self.catalog === catalog else { return }
        for line in lines.values { line.task.cancel() }
        lines = [:]
        self.catalog = nil
        server = nil
        changed()
    }

    /// Reads the folder again for messages another process saved, such as the share extension.
    func reload() {
        scan()
        wake()
    }

    /// The server may be reachable again, so every delivery waiting for a connection tries now.
    func wake() {
        for (id, pause) in pauses where pause.wakesEarly { resume(id) }
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

    /// A channel's stream reported the channel deleted, so its messages leave with it.
    func channelDeleted(_ channelID: String, on server: URL) {
        let key = Self.key(server)
        let gone = queue.filter { $0.server == key && $0.channelID == channelID }.map(\.id)
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

    // MARK: Handing off to iOS

    /// Hands each channel's next message to iOS as a background upload, for the phone's app delegate
    /// when its background time is about to end. iOS finishes it even if Toy Box stops running, and
    /// its answer comes back through the same confirmation. The outbox keeps trying as well, since the
    /// server ignores whichever arrives second, and only the next message goes, so a channel's
    /// messages still arrive in order. Returns once iOS has every upload, so background time can end.
    public func handOff() async {
        startUploads()
        await writes?.value
    }

    private func startUploads() {
        guard let uploads, let catalog, let server else { return }
        var channels = Set<String>()
        for message in queue where message.server == server && message.state == .sending {
            guard channels.insert(message.channelID).inserted, !uploading.contains(message.id) else { continue }
            let request: URLRequest
            do {
                request = try catalog.api.messageRequest(channelId: message.channelID, id: message.id.uuidString,
                                                         content: message.text, attachments: message.attachments)
            } catch { continue }
            uploading.insert(message.id)
            let id = message.id
            write { uploads.start(request, id: id) }
        }
    }

    /// iOS relaunched or woke the app with finished uploads, from its own session or the share
    /// extension's. `completion` runs once they're applied. False for a session that isn't the outbox's.
    @discardableResult
    public func handleEvents(forBackgroundSession session: String, completion: @escaping () -> Void) -> Bool {
        guard let uploads, session.hasPrefix(uploads.session) else { return false }
        completions[session] = completion
        // Reads the share extension's messages before its uploads report.
        reload()
        uploads.open(session)
        return true
    }

    private func listen(to uploads: any Uploads) {
        listening = Task { [weak self] in
            for await upload in uploads.events { await self?.apply(upload) }
        }
    }

    private func apply(_ upload: Upload) async {
        switch upload {
        case .finished(let id, let response, let data, let error):
            await scanning?.value
            uploading.remove(id)
            guard let message = message(id) else { return }
            let outcome = if let error { Outcome(error) }
                else if let response { Outcome(response, data: data, isLive: catalog?.isLive ?? false, now: now()) }
                else { Outcome.trouble(retryAfter: nil) }
            switch outcome {
            case .accepted(let sent): confirm(id, merging: sent)
            case .rejected where message.state == .sending: stop(id)
            // Still Sending, so the outbox keeps trying while Toy Box runs, or at its next launch.
            default: Self.logger.info("A background upload didn't confirm a message")
            }
        case .delivered(let session):
            await settled()
            completions.removeValue(forKey: session)?()
        }
    }

    // MARK: Delivery

    private struct Line {
        let token: UUID
        let task: Task<Void, Never>
    }

    private struct Pause {
        let message: UUID
        let continuation: CheckedContinuation<Void, Never>
        let wakesEarly: Bool
        var timer: Task<Void, Never>?
    }

    /// Recomputes what depends on the queue and starts a line for each channel with a message to send.
    private func changed() {
        let delivering = reads > 0
            || server.map { server in queue.contains { $0.server == server && $0.state == .sending } } ?? false
        if isDelivering != delivering { isDelivering = delivering }
        guard isLoaded, let catalog, let server else { return }
        if handsOff { return startUploads() }
        let api = catalog.api
        let channels = Set(queue.lazy.filter { $0.server == server && $0.state == .sending }.map(\.channelID))
        for channelID in channels where lines[channelID] == nil {
            let token = UUID()
            lines[channelID] = Line(token: token, task: Task { [weak self] in
                await self?.deliver(in: channelID, server: server, api: api)
                self?.lineEnded(channelID, token: token)
            })
        }
    }

    private func lineEnded(_ channelID: String, token: UUID) {
        guard lines[channelID]?.token == token else { return }
        lines[channelID] = nil
        changed()
    }

    /// Sends a channel's messages one at a time, oldest first. A Not sent message steps out of line.
    private func deliver(in channelID: String, server: String, api: ChannelAPI) async {
        while !Task.isCancelled, let next = queue.first(where: {
            $0.server == server && $0.channelID == channelID && $0.state == .sending
        }) {
            await deliver(next.id, api: api)
        }
    }

    /// Tries until the server confirms or refuses the message, or it stops being Sending.
    private func deliver(_ id: UUID, api: ChannelAPI) async {
        var troubleSince: Date?
        var troubleCount = 0
        var waits = 0
        while !Task.isCancelled, let message = self.message(id), message.state == .sending {
            let store = catalog?.existingChannel(id: message.channelID)
            if store?.holds(id) == true { return confirm(id) }
            let started = now()
            let outcome = await post(message, api: api)
            guard !Task.isCancelled, self.message(id)?.state == .sending else { return }
            switch outcome {
            case .accepted(let sent):
                confirm(id, merging: sent)
                // A 409 returns nothing, so an open channel resumes from its last revision to show it.
                if sent == nil, let store, store.isTrying, !store.holds(id) { store.reconnect() }
                return
            case .rejected:
                return stop(id)
            case .unreachable:
                troubleSince = nil
                troubleCount = 0
                await pause(id, for: reconnectPolicy.delay(attempt: waits), wakesEarly: true)
                waits += 1
            case .trouble(let retryAfter):
                waits = 0
                let since = troubleSince ?? started
                troubleSince = since
                let delay = max(Self.backoff(troubleCount), retryAfter ?? 0)
                troubleCount += 1
                guard now().timeIntervalSince(since) + delay <= retryWindow else { return stop(id) }
                await pause(id, for: delay, wakesEarly: false)
            }
        }
    }

    static func backoff(_ attempt: Int) -> TimeInterval {
        let steps: [TimeInterval] = [1, 2, 4, 8, 15, 30]
        return attempt < steps.count ? steps[attempt] : 60
    }

    private func post(_ message: Message, api: ChannelAPI) async -> Outcome {
        let request: URLRequest
        do {
            request = try api.messageRequest(channelId: message.channelID, id: message.id.uuidString,
                                             content: message.text, attachments: message.attachments)
        } catch {
            Self.logger.error("A message can't be sent: \(error.localizedDescription)")
            return .rejected
        }
        do {
            let (data, response) = try await api.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return .trouble(retryAfter: nil) }
            let outcome = Outcome(response, data: data, isLive: catalog?.isLive ?? false, now: now())
            if case .accepted = outcome { return outcome }
            let failure = ChannelAPI.failure(status: response.statusCode, data: data)
            Self.logger.info("Sending got \(response.statusCode): \(failure.localizedDescription)")
            return outcome
        } catch {
            Self.logger.info("Sending failed: \(error.localizedDescription)")
            return Outcome(error)
        }
    }

    /// Waits for `seconds`, or until `wake()` when `wakesEarly`. Cancelling the task, or the message
    /// leaving the queue, ends it at once.
    private func pause(_ message: UUID, for seconds: TimeInterval, wakesEarly: Bool) async {
        let id = UUID()
        let sleep = sleep
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pauses[id] = Pause(message: message, continuation: continuation, wakesEarly: wakesEarly)
                pauses[id]?.timer = Task { [weak self] in
                    try? await sleep(seconds)
                    self?.resume(id)
                }
                if Task.isCancelled { resume(id) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id) }
        }
    }

    private func resume(_ id: UUID) {
        guard let pause = pauses.removeValue(forKey: id) else { return }
        pause.timer?.cancel()
        pause.continuation.resume()
    }

    private func confirm(_ id: UUID, merging sent: ChannelMessage? = nil) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let message = queue.remove(at: index)
        removed.insert(id)
        delete(id)
        release(id)
        let destination = Destination(server: message.server, channelID: message.channelID)
        if let request = message.request { answered[destination, default: []].insert(request) }
        if message.server == server, let catalog {
            let store = catalog.existingChannel(id: message.channelID)
            if let sent { store?.mergeSent(sent) }
            // The user's own message never leaves its channel unread. A 409 brings no sequence, so it
            // marks nothing unless the open channel already has the message.
            if let through = sent?.sequence ?? store?.sequence(ofSent: id) {
                markRead(message.channelID, through: through, api: catalog.api)
            }
            catalog.onSendConfirmed?(message.channelID)
        }
        changed()
    }

    /// One attempt, logging a failure. It counts as delivering, so the phone's background time covers it.
    private func markRead(_ channelID: String, through sequence: Int, api: ChannelAPI) {
        reads += 1
        Task {
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
        release(id)
    }

    /// Ends a removed message's pause, so its line moves on to the next message.
    private func release(_ message: UUID) {
        for (id, pause) in pauses where pause.message == message { resume(id) }
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
        case trouble(retryAfter: TimeInterval?)
        /// The server refused it, so the message stops as Not sent.
        case rejected

        /// A gateway answers these for a server that isn't running, as Tailscale Serve and Cloudflare
        /// Tunnel do while the Mac sleeps. With the catalog connected, the server itself is in trouble.
        static let gatewayStatuses: Set<Int> = [502, 503, 504, 530]

        static let unreachableErrors: Set<URLError.Code> = [
            .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive, .cancelled,
        ]

        init(_ response: HTTPURLResponse, data: Data, isLive: Bool, now: Date) {
            let status = response.statusCode
            switch status {
            case 200..<300: self = .accepted(ChannelAPI.sentMessage(in: data))
            case 409: self = .accepted(nil)
            case _ where Self.gatewayStatuses.contains(status) && !isLive: self = .unreachable
            case 408, 429, 500...:
                self = .trouble(retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now))
            case 400..<500: self = .rejected
            default: self = .trouble(retryAfter: nil)
            }
        }

        init(_ error: any Error) {
            if let error = error as? URLError, Self.unreachableErrors.contains(error.code) {
                self = .unreachable
            } else {
                self = .trouble(retryAfter: nil)
            }
        }

        /// Seconds, or an HTTP date.
        static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            if let seconds = TimeInterval(value) { return max(0, seconds) }
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(identifier: "GMT")
            format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return format.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
        }
    }
}

extension ChannelOutbox.Message {
    /// The row the store's `sendAttempts` shows, until every view reads the outbox.
    var attempt: ChannelSendAttempt {
        .init(id: id.uuidString, content: text, attachments: attachments, timestamp: message.timestamp,
              phase: state == .sending ? .sending : .notSent)
    }
}
