import ChannelKit
import Foundation

public struct SSEFrame: Equatable, Sendable {
    public var data: String
    public var id: String?
    public var event: String?
    public var retryMilliseconds: Int?
}

public struct SSEDecoder: Sendable {
    private var line: [UInt8] = []
    private var data: [String] = []
    private var id: String?
    private var event: String?
    private var retry: Int?
    private var skipLF = false
    private var isFirstLine = true
    private var eventSize = 0
    public let maximumEventBytes: Int

    public init(maximumEventBytes: Int = 32 * 1024 * 1024) {
        self.maximumEventBytes = maximumEventBytes
    }

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
                event = nil
                retry = nil
                eventSize = 0
            }
            guard !data.isEmpty else { return nil }
            return SSEFrame(data: data.joined(separator: "\n"), id: id,
                            event: event, retryMilliseconds: retry)
        }
        if text.hasPrefix(":") { return nil }
        let field: String
        var value: String
        if let colon = text.firstIndex(of: ":") {
            field = String(text[..<colon])
            value = String(text[text.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else { field = text; value = "" }
        switch field {
        case "data":
            eventSize += value.utf8.count + 1
            guard eventSize <= maximumEventBytes else { throw ChannelAPIError.invalidEvent("oversized SSE") }
            data.append(value)
        case "id":
            if !value.contains("\0") { id = value }
        case "event": event = value
        case "retry":
            if !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }) { retry = Int(value) }
        default: break
        }
        return nil
    }
}

private actor Heartbeat {
    var last = ContinuousClock.now
    func touch() { last = .now }
    func expired(after seconds: TimeInterval) -> Bool {
        last.duration(to: .now) > .seconds(seconds)
    }
}

enum ChannelObservationStage: Equatable, Sendable {
    case streamRequested(after: Int?)
    case responseReceived(status: Int)
    case eventDecoded(type: String, revision: Int?)
    case eventReceived(type: String)
    case eventApplied(type: String, revision: Int?)
    case eventHandled(type: String)
    case streamFinished(error: String?)
    case reconnectPending(attempt: Int)
    case reconnectScheduled(attempt: Int, delay: TimeInterval, after: Int?)
    case reconnectDelayElapsed
    case reconnectRequested(after: Int?)
}

public extension ChannelAPI {
    func observe(channelId: String, after: Int? = nil,
                 heartbeatTimeout: TimeInterval = 35) -> AsyncThrowingStream<ChannelObservationEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = streamRequest(channelId: channelId, after: after, timeout: heartbeatTimeout)
                    observationTrace?(.streamRequested(after: after))
                    let heartbeat = Heartbeat()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            let (bytes, response) = try await session.bytes(for: request)
                            guard let http = response as? HTTPURLResponse else {
                                throw ChannelAPIError.invalidResponse
                            }
                            observationTrace?(.responseReceived(status: http.statusCode))
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
                            var frameDecoder = SSEDecoder()
                            let eventDecoder = JSONDecoder()
                            var count = 0
                            for try await byte in bytes {
                                try Task.checkCancellation()
                                count += 1
                                if byte == 10 || byte == 13 || count % 4096 == 0 { await heartbeat.touch() }
                                if let frame = try frameDecoder.consume(byte) {
                                    let event = try eventDecoder.decode(ChannelObservationEvent.self,
                                                                        from: Data(frame.data.utf8))
                                    try validate(event)
                                    observationTrace?(.eventDecoded(
                                        type: event.type, revision: event.revision ?? event.state?.revision
                                    ))
                                    continuation.yield(event)
                                    if event.type == "deleted" { return }
                                }
                            }
                            throw ChannelAPIError.streamEnded
                        }
                        group.addTask {
                            while true {
                                try await Task.sleep(for: .seconds(min(heartbeatTimeout / 3, 1)))
                                if await heartbeat.expired(after: heartbeatTimeout) {
                                    throw ChannelAPIError.heartbeatTimeout
                                }
                            }
                        }
                        defer { group.cancelAll() }
                        _ = try await group.next()
                    }
                    observationTrace?(.streamFinished(error: nil))
                    continuation.finish()
                } catch let error as URLError where error.code == .timedOut {
                    observationTrace?(.streamFinished(error: ChannelAPIError.heartbeatTimeout.localizedDescription))
                    continuation.finish(throwing: ChannelAPIError.heartbeatTimeout)
                } catch {
                    observationTrace?(.streamFinished(error: String(describing: error)))
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

public struct ReconnectPolicy: Sendable {
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval

    public init(initialDelay: TimeInterval = 0.5, maximumDelay: TimeInterval = 15) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
    }

    public func delay(attempt: Int) -> TimeInterval {
        min(maximumDelay, initialDelay * pow(2, Double(min(max(0, attempt), 20))))
    }
}
