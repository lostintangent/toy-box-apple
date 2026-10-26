import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

@Suite("Server connection probe", .timeLimit(.minutes(1)))
@MainActor
struct ServerConnectionProbeTests {
    @Test(arguments: [
        ("localhost", true), ("mac.localhost", true), ("127.0.0.1", true), ("127.9.8.7", true),
        ("::1", true), ("192.168.1.10", false), ("100.64.0.10", false), ("mac.example", false),
    ])
    func loopbackClassificationRetainsTheMacFolderPolicy(host: String, expected: Bool) {
        #expect(isLoopbackHost(host) == expected)
    }

    private final class ControlledCatalog: Sendable {
        struct Request: Sendable {
            let api: ChannelAPI
            let completion: CheckedContinuation<ChannelCatalog, any Error>
        }

        let requests: AsyncStream<Request>
        private let continuation: AsyncStream<Request>.Continuation

        init() {
            (requests, continuation) = AsyncStream.makeStream()
        }

        func load(_ api: ChannelAPI) async throws -> ChannelCatalog {
            try await withCheckedThrowingContinuation {
                continuation.yield(Request(api: api, completion: $0))
            }
        }
    }

    @Test func theProbeUsesTheFullPrefixAndOnlyReadsTheCatalog() async throws {
        let catalog = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel])
        let mock = MockTransport { request, _ in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/prefix/api/v1/channels")
            return try .json(catalog)
        }
        let api = try mock.api()
        let probe = ServerConnectionProbe(address: api.baseURL.absoluteString + "/prefix", session: api.session)
        let operation = try #require(probe.start())
        #expect(probe.isTesting)
        await operation.value
        guard case .connected(let url, let count) = probe.phase else {
            Issue.record("The valid catalog did not produce a connected result.")
            return
        }
        #expect(url.path == "/prefix")
        #expect(count == 1)
        #expect(mock.requests.count == 1)
    }

    @Test func missingLeadRemainsAProtocolFailure() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(body: Data(#"{"version":1,"channels":[],"members":[]}"#.utf8))
        }
        let api = try mock.api()
        let probe = ServerConnectionProbe(address: api.baseURL.absoluteString, session: api.session)
        await probe.start()?.value
        guard case .failed(let address, let error) = probe.phase else {
            Issue.record("A missing Lead was reported as connected.")
            return
        }
        #expect(address == api.baseURL.absoluteString)
        #expect(error is DecodingError)
    }

    @Test func invalidInputStartsNoRequestAndSurfacesItsError() throws {
        let mock = MockTransport { _, _ in
            Issue.record("Invalid input reached the transport.")
            return MockResponse()
        }
        let api = try mock.api()
        let probe = ServerConnectionProbe(address: "file:///not-a-server", session: api.session)
        #expect(probe.validationError != nil)
        #expect(probe.start() == nil)
        guard case .failed(_, let error) = probe.phase else {
            Issue.record("Invalid input did not retain a failure.")
            return
        }
        #expect(error as? ChannelAPIError == .invalidServerURL)
        #expect(mock.requests.isEmpty)
    }

    @Test(arguments: [true, false])
    func changingTheAddressRejectsOldSuccessAndFailure(oldSucceeds: Bool) async throws {
        let controlled = ControlledCatalog()
        let probe = ServerConnectionProbe(address: "https://first.example", loadCatalog: controlled.load)
        var requests = controlled.requests.makeAsyncIterator()
        let first = try #require(probe.start())
        let old = try #require(await requests.next())
        probe.address = "https://second.example/prefix"
        #expect(!probe.isTesting)
        let second = try #require(probe.start())
        let current = try #require(await requests.next())
        #expect(current.api.baseURL.absoluteString == probe.address)
        current.completion.resume(returning: ChannelCatalog(lead: testLeadProfile))
        await second.value
        if oldSucceeds {
            old.completion.resume(returning: ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
        } else {
            old.completion.resume(throwing: ChannelAPIError.http(status: 503, message: "Old server"))
        }
        await first.value
        guard case .connected(let url, let count) = probe.phase else {
            Issue.record("An obsolete completion replaced the current successful probe.")
            return
        }
        #expect(url.absoluteString == "https://second.example/prefix")
        #expect(count == 0)
    }

    @Test func restartingTheSameAddressRejectsItsPriorGeneration() async throws {
        let controlled = ControlledCatalog()
        let probe = ServerConnectionProbe(address: "https://fixture.example", loadCatalog: controlled.load)
        var requests = controlled.requests.makeAsyncIterator()
        let first = try #require(probe.start())
        let old = try #require(await requests.next())
        let second = try #require(probe.start())
        let current = try #require(await requests.next())
        current.completion.resume(throwing: ChannelAPIError.http(status: 401, message: "Current authorization"))
        await second.value
        old.completion.resume(returning: ChannelCatalog(lead: testLeadProfile))
        await first.value
        guard case .failed(let address, let error) = probe.phase else {
            Issue.record("The prior generation replaced the current failure.")
            return
        }
        #expect(address == "https://fixture.example")
        #expect(error as? ChannelAPIError == .http(status: 401, message: "Current authorization"))
    }

    @Test func cancelClearsTheResultEvenWhenTheLoaderIgnoresCancellation() async throws {
        let controlled = ControlledCatalog()
        let probe = ServerConnectionProbe(address: "https://fixture.example", loadCatalog: controlled.load)
        var requests = controlled.requests.makeAsyncIterator()
        let operation = try #require(probe.start())
        let request = try #require(await requests.next())
        probe.cancel()
        request.completion.resume(returning: ChannelCatalog(lead: testLeadProfile))
        await operation.value
        guard case .idle = probe.phase else {
            Issue.record("A canceled probe published its result.")
            return
        }
    }
}
