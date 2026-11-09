import ChannelKit
import Foundation
import Synchronization

/// A block of an SSE stream, complete once its blank line arrives.
public enum SSEFrame: Equatable, Sendable {
    /// An event's data. Its other fields are never read.
    case event(String)
    /// A block of only comments, which a server sends to keep an idle stream open.
    case keepalive
}

public struct SSEDecoder: Sendable {
    private var line: [UInt8] = []
    private var data: [String] = []
    private var hasComment = false
    private var skipLF = false
    private var isFirstLine = true
    private var eventSize = 0
    public let maximumEventBytes: Int

    public init(maximumEventBytes: Int = 32 * 1024 * 1024) {
        self.maximumEventBytes = maximumEventBytes
    }

    /// Returns a block once its blank line arrives. A block with neither data nor a comment returns nil.
    public mutating func consume(_ byte: UInt8) throws -> SSEFrame? {
        if skipLF {
            skipLF = false
            if byte == 10 { return nil }
        }
        if byte == 10 || byte == 13 {
            skipLF = byte == 13
            return try finishLine()
        }
        line.append(byte)
        guard line.count + eventSize <= maximumEventBytes else {
            throw ChannelAPIError.invalidEvent("oversized SSE")
        }
        return nil
    }

    private mutating func finishLine() throws -> SSEFrame? {
        guard var text = String(bytes: line, encoding: .utf8) else {
            throw ChannelAPIError.invalidEvent("UTF-8 SSE")
        }
        line.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if text.first == "\u{FEFF}" { text.removeFirst() }
        }
        if text.isEmpty {
            defer {
                data.removeAll(keepingCapacity: true)
                hasComment = false
                eventSize = 0
            }
            if !data.isEmpty { return .event(data.joined(separator: "\n")) }
            return hasComment ? .keepalive : nil
        }
        if text.first == ":" { hasComment = true }
        guard text == "data" || text.hasPrefix("data:") else { return nil }
        var value = text.dropFirst(5)
        if value.first == " " { value.removeFirst() }
        eventSize += value.utf8.count + 1
        guard eventSize <= maximumEventBytes else { throw ChannelAPIError.invalidEvent("oversized SSE") }
        data.append(String(value))
        return nil
    }
}

public extension ChannelAPI {
    /// The server sends a keepalive well inside `heartbeatTimeout`, so that much silence fails the
    /// stream. The request's own timeout enforces it, since URLSession times out a stream that
    /// receives nothing for its timeout interval.
    func observe(channelId: String, after: Int? = nil,
                 heartbeatTimeout: TimeInterval = 35) -> AsyncThrowingStream<ChannelObservationEvent, any Error> {
        observe(channelId: channelId, after: after, heartbeatTimeout: heartbeatTimeout, arrivals: nil)
    }

    /// Notes each byte of an accepted stream in `arrivals`, before any event completes.
    ///
    /// The task that reads the stream opens its request, at the first event it asks for, and the
    /// request closes when that task stops reading. So a stream nobody reads never connects, and a
    /// reader cancelled first never touches a session its owner may since have invalidated.
    internal func observe(channelId: String, after: Int?, heartbeatTimeout: TimeInterval = 35,
                          arrivals: StreamArrivals?) -> AsyncThrowingStream<ChannelObservationEvent, any Error> {
        let reader = SSEReader<ChannelObservationEvent>(
            session: streamSession,
            request: streamRequest(channelId: channelId, after: after, timeout: heartbeatTimeout),
            arrivals: arrivals
        ) { event in
            try validate(event)
            return event.type == "deleted"
        }
        return AsyncThrowingStream {
            while let item = try await reader.next() {
                if case .event(let event) = item { return event }
            }
            return nil
        }
    }

    /// The catalog stream: a snapshot, then each change, with a keepalive while nothing changes.
    /// It has no cursor, so every reconnect opens with a fresh snapshot. It opens the way a
    /// channel's stream does, and fails on the same silence.
    internal func observeCatalog(heartbeatTimeout: TimeInterval = 35)
        -> AsyncThrowingStream<SSEItem<ChannelCatalogEvent>, any Error> {
        var request = URLRequest(url: endpoint(["api", "v1", "channels"]),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: heartbeatTimeout)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let reader = SSEReader<ChannelCatalogEvent>(session: streamSession, request: request,
                                                    arrivals: nil) { _ in false }
        return AsyncThrowingStream { try await reader.next() }
    }
}

/// What a stream read: an event, or a keepalive that says the stream is still open.
enum SSEItem<Event: Sendable>: Sendable {
    case event(Event)
    case keepalive
}

/// One stream's request and decoder. Only the task iterating the stream touches them, one event at a
/// time, so they need no lock.
private final class SSEReader<Event: Decodable & Sendable>: @unchecked Sendable {
    private let session: URLSession
    private let request: URLRequest
    private let arrivals: StreamArrivals?
    /// Throws for an event the stream can't accept, and returns whether the stream ends after it.
    private let check: @Sendable (Event) throws -> Bool
    private var bytes: URLSession.AsyncBytes.AsyncIterator?
    private var task: URLSessionDataTask?
    private var frames = SSEDecoder()
    private let decoder = JSONDecoder()
    private var isFinished = false

    init(session: URLSession, request: URLRequest, arrivals: StreamArrivals?,
         check: @escaping @Sendable (Event) throws -> Bool) {
        self.session = session
        self.request = request
        self.arrivals = arrivals
        self.check = check
    }

    /// A reader that stops early releases the stream without finishing it.
    deinit { task?.cancel() }

    func next() async throws -> SSEItem<Event>? {
        guard !isFinished else { return nil }
        do {
            var iterator: URLSession.AsyncBytes.AsyncIterator
            if let current = bytes.take() { iterator = current } else { iterator = try await open() }
            while let byte = try await iterator.next() {
                try Task.checkCancellation()
                arrivals?.received()
                switch try frames.consume(byte) {
                case nil:
                    continue
                case .keepalive:
                    bytes = iterator
                    return .keepalive
                case .event(let payload):
                    let event = try decoder.decode(Event.self, from: Data(payload.utf8))
                    if try check(event) { finish() } else { bytes = iterator }
                    return .event(event)
                }
            }
            throw ChannelAPIError.streamEnded
        } catch let error as URLError where error.code == .timedOut {
            finish()
            throw ChannelAPIError.heartbeatTimeout
        } catch {
            finish()
            throw error
        }
    }

    private func open() async throws -> URLSession.AsyncBytes.AsyncIterator {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        task = bytes.task
        guard let http = response as? HTTPURLResponse else { throw ChannelAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ChannelAPIError.http(
                status: http.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().hasPrefix("text/event-stream") == true else {
            throw ChannelAPIError.invalidResponse
        }
        return bytes.makeAsyncIterator()
    }

    private func finish() {
        isFinished = true
        bytes = nil
        task?.cancel()
    }
}

private func validate(_ event: ChannelObservationEvent) throws {
    let valid: Bool
    switch event.type {
    case "snapshot": valid = event.state != nil
    case "presence", "resumed": valid = event.presence != nil
    case "deleted": valid = event.channelId != nil
    case "message": valid = event.revision != nil && event.message != nil
    case "reaction": valid = event.revision != nil && event.sequence != nil && event.agentId != nil
    case "tasks": valid = event.revision != nil && event.tasks != nil
    case "model": valid = event.revision != nil && event.model != nil && event.updatedAt != nil
    case "read": valid = event.revision != nil && event.seenThrough != nil
    case "member": valid = event.revision != nil && event.member != nil
    case "status": valid = event.revision != nil && event.agentId != nil
    default: valid = true
    }
    guard valid else { throw ChannelAPIError.invalidEvent(event.type) }
}

/// Tells a channel's store that its stream is receiving, so a large snapshot on a slow link reads as
/// arriving rather than silent. It reports once, then stays quiet until the store's grace rearms it,
/// so a byte costs one relaxed load.
final class StreamArrivals: Sendable {
    private let reported = Atomic(false)
    private let report: @Sendable () -> Void

    init(_ report: @escaping @Sendable () -> Void) { self.report = report }

    func received() {
        guard !reported.load(ordering: .relaxed) else { return }
        reported.store(true, ordering: .relaxed)
        report()
    }

    func rearm() { reported.store(false, ordering: .relaxed) }
}

public struct ReconnectPolicy: Sendable {
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    /// How long a channel tries to connect with nothing arriving before it reports `.failed`, and
    /// how long the catalog's stream keeps failing before it reports. Until then nothing changes, so
    /// a quick reconnect after coming back to the app shows no notice.
    public var grace: TimeInterval

    public init(initialDelay: TimeInterval = 0.5, maximumDelay: TimeInterval = 15, grace: TimeInterval = 3) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.grace = grace
    }

    public func delay(attempt: Int) -> TimeInterval {
        min(maximumDelay, initialDelay * pow(2, Double(min(max(0, attempt), 20))))
    }
}
