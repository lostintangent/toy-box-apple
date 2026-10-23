import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

struct MockResponse: Sendable {
    var status = 200
    var contentType = "application/json"
    var body = Data()
    var keepOpen = false

    static func json<Value: Encodable>(_ value: Value, status: Int = 200) throws -> MockResponse {
        MockResponse(status: status, body: try JSONEncoder().encode(value))
    }

    static func stream(_ events: [ChannelObservationEvent], keepOpen: Bool = true) throws -> MockResponse {
        let data = try events.map { "data: " + String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n\n" }
            .joined()
        return MockResponse(contentType: "text/event-stream", body: Data(data.utf8), keepOpen: keepOpen)
    }
}

final class MockTransport: Sendable {
    typealias Handler = @Sendable (URLRequest, Int) throws -> MockResponse
    struct State {
        var requests: [URLRequest] = []
        var stops = 0
        var pending: [ObjectIdentifier: MockURLProtocol] = [:]
    }
    let state = Mutex(State())
    let handler: Handler
    let host = UUID().uuidString.lowercased() + ".example"

    init(handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { state.withLock { $0.requests } }
    var stops: Int { state.withLock { $0.stops } }
    var pendingResponseCount: Int { state.withLock { $0.pending.count } }

    @discardableResult
    func finishPendingResponses() -> Int {
        let pending = state.withLock { state in
            let pending = Array(state.pending.values)
            state.pending.removeAll()
            return pending
        }
        for response in pending { response.client?.urlProtocolDidFinishLoading(response) }
        return pending.count
    }

    func response(for request: URLRequest) throws -> MockResponse {
        let count = state.withLock { state in
            state.requests.append(request)
            return state.requests.count
        }
        return try handler(request, count)
    }

    func api() throws -> ChannelAPI {
        MockURLProtocol.registry.withLock { $0[host] = self }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return try ChannelAPI(serverURL: "http://\(host)", session: URLSession(configuration: configuration))
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = Mutex<[String: MockTransport]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host,
              let transport = Self.registry.withLock({ $0[host] }),
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: ChannelAPIError.invalidResponse)
            return
        }
        do {
            let value = try transport.response(for: request)
            let response = HTTPURLResponse(url: url, statusCode: value.status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": value.contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !value.body.isEmpty { client?.urlProtocol(self, didLoad: value.body) }
            if value.keepOpen {
                transport.state.withLock { $0.pending[ObjectIdentifier(self)] = self }
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {
        if let host = request.url?.host, let transport = Self.registry.withLock({ $0[host] }) {
            transport.state.withLock {
                $0.stops += 1
                $0.pending.removeValue(forKey: ObjectIdentifier(self))
            }
        }
    }
}

func requestBody(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    let stream = try #require(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let length = stream.read(&buffer, maxLength: buffer.count)
        guard length >= 0 else { throw ChannelAPIError.invalidResponse }
        if length == 0 { break }
        data.append(contentsOf: buffer.prefix(length))
    }
    return data
}

let testLeadProfile = ChannelLeadProfile(name: "Lead", role: "Test channel coordinator.",
                                         avatar: .init(mark: "M4 12H20", color: "#123456"))

func testState(revision: Int = 0, messages: [ChannelMessage] = []) -> ChannelState {
    let channel = Channel(id: "test", name: "Test", model: .init(provider: "test", name: "test"),
                          latestSequence: messages.last?.sequence ?? 0, updatedAt: "2026-10-01T00:00:00Z")
    return .init(revision: revision, channel: channel,
                 lead: .lead(id: "test", profile: testLeadProfile), messages: messages)
}

func testMessage(_ sequence: Int, id: String? = nil, text: String = "Progress") -> ChannelMessage {
    .init(id: id ?? "m\(sequence)", sequence: sequence, timestamp: "2026-10-01T00:00:00Z",
          sender: .agent("test"), content: .text(text))
}

@MainActor
func eventually(_ condition: () -> Bool, timeout: TimeInterval = 3) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Condition was not reached within \(timeout) seconds.")
            throw ChannelAPIError.invalidResponse
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
