import ChannelKit
import Foundation
import Synchronization

public struct SSEDecoder: Sendable {
    private var line: [UInt8] = []
    private var data: [String] = []
    private var skipLF = false
    private var isFirstLine = true
    private var eventSize = 0
    public let maximumEventBytes: Int

    public init(maximumEventBytes: Int = 32 * 1024 * 1024) {
        self.maximumEventBytes = maximumEventBytes
    }

    /// Returns an event's data once its blank line arrives. Its other fields are never read.
    public mutating func consume(_ byte: UInt8) throws -> String? {
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

    private mutating func finishLine() throws -> String? {
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
                eventSize = 0
            }
            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
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
    internal func observe(channelId: String, after: Int?, heartbeatTimeout: TimeInterval = 35,
                          arrivals: StreamArrivals?) -> AsyncThrowingStream<ChannelObservationEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = streamRequest(channelId: channelId, after: after, timeout: heartbeatTimeout)
                    let (bytes, response) = try await session.bytes(for: request)
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
                    var frames = SSEDecoder()
                    let decoder = JSONDecoder()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        arrivals?.received()
                        guard let payload = try frames.consume(byte) else { continue }
                        let event = try decoder.decode(ChannelObservationEvent.self, from: Data(payload.utf8))
                        try validate(event)
                        continuation.yield(event)
                        if event.type == "deleted" { return continuation.finish() }
                    }
                    throw ChannelAPIError.streamEnded
                } catch let error as URLError where error.code == .timedOut {
                    continuation.finish(throwing: ChannelAPIError.heartbeatTimeout)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
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
    /// how long catalog polls keep failing before they report. Until then nothing changes, so a
    /// quick reconnect after coming back to the app shows no notice.
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
