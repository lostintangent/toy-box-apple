import AppIntents
import AppKit
@testable import ChannelClient
import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ToyBoxDesktop

@MainActor @Suite(.serialized)
struct RequestSpotlightTests {
    @Test func entityUsesTheInboxQuestionIdentityAndCatalogAvatar() throws {
        let entry = try entry()
        let png = try #require(RequestSpotlight.renderAvatar(entry.agent))
        let image = try #require(NSBitmapImageRep(data: png))
        #expect(image.pixelsWide == 128 && image.pixelsHigh == 128)
        let entity = WaitingRequestEntity(entry, thumbnail: png)
        #expect(String(localized: entity.displayRepresentation.title) == "Should we ship the caf\u{00e9} layout?")
        #expect(entity.attributeSet.contentDescription == "Lead \u{00b7} Studio")
        #expect(entity.attributeSet.thumbnailData == png)
        #expect(entity.attributeSet.keywords == ["Lead", "Studio", "Needs your reply"])
        #expect(NeedsYouRequestLink(url: try #require(URL(string: entity.id))) == entry.link)
        #expect(try self.entry(server: "https://other.test").id != entry.id)
        #expect(try self.entry(server: "HTTPS://SERVER.TEST:443/").id == entry.id)
        #expect(try self.entry(server: "https://server.test/a%2Fb").id != self.entry(server: "https://server.test/a/b").id)
        #expect(try self.entry(sequence: 9).id != entry.id)
        #expect(WaitingRequestQuery.matching("CAFE", in: [entity]).count == 1)
        #expect(WaitingRequestQuery.matching("studio", in: [entity]).count == 1)
        #expect(WaitingRequestQuery.matching("Lead", in: [entity]).count == 1)
        #expect(WaitingRequestQuery.matching("missing", in: [entity]).isEmpty)
    }

    @Test func unresolvedQuestionsNeverBecomePlaceholderSearchResults() throws {
        var item = item()
        item.quote = nil
        #expect(WaitingRequestEntry(item: item, serverURL: "https://server.test") == nil)
        item = self.item()
        item.agent = nil
        #expect(WaitingRequestEntry(item: item, serverURL: "https://server.test") == nil)
        item = self.item()
        item.sequence = 0
        #expect(WaitingRequestEntry(item: item, serverURL: "https://server.test") == nil)
    }

    @Test func resolvedAgentlessRequestsDoNotDelayHealthyResults() async throws {
        let healthy = item()
        var removedRequester = item(sequence: 9)
        removedRequester.agent = nil
        var polls = 0
        let resolved = try await ChannelIntentsContext.resolveWaitingRequests {
            polls += 1
            return ("https://server.test", true, [healthy, removedRequester])
        }
        let expectedID = try entry().id
        #expect(polls == 1 && resolved.map(\.id) == [expectedID])
    }

    @Test func aFailedHistoryLookupReturnsTheHealthySubsetAtTheDeadline() async throws {
        let healthy = item()
        var unresolved = item(sequence: 9)
        unresolved.quote = nil
        let resolved = try await ChannelIntentsContext.resolveWaitingRequests(timeout: .zero) {
            ("https://server.test", true, [healthy, unresolved])
        }
        #expect(resolved.map(\.id) == [try entry().id])
        await #expect(throws: ChannelIntentError.unreachable) {
            try await ChannelIntentsContext.resolveWaitingRequests(timeout: .zero) {
                throw ChannelIntentError.unreachable
            }
        }
    }

    @Test func answeredAndReplacedRequestsLeaveTheIndexAndServerSwitchClearsIt() async throws {
        let fake = FakeRequestIndex()
        let spotlight = RequestSpotlight(index: fake.index, icon: { _ in Data([1]) })
        let first = try entry(), second = try entry(sequence: 9)
        spotlight.update(.init(server: "server", entries: nil))
        await spotlight.settle()
        #expect(fake.operations.isEmpty)
        spotlight.update(.init(server: "server", entries: [first, first]))
        await spotlight.settle()
        #expect(fake.operations == [.clear, .add([first.id])])
        spotlight.update(.init(server: "server", entries: [second]))
        await spotlight.settle()
        #expect(fake.operations.suffix(2) == [.remove([first.id]), .add([second.id])])
        spotlight.update(.init(server: "server", entries: []))
        await spotlight.settle()
        #expect(fake.operations.last == .remove([second.id]))
        spotlight.update(.init(server: "other", entries: nil))
        await spotlight.settle()
        #expect(fake.operations.last == .clear)
        let count = fake.operations.count
        spotlight.update(.init(server: "other", entries: nil))
        await spotlight.settle()
        #expect(fake.operations.count == count)
    }

    @Test func queuedChangesReconcileAgainstTheLastSuccessfulWriteAndReindexRemovesUnknownIDs() async throws {
        let fake = FakeRequestIndex()
        let spotlight = RequestSpotlight(index: fake.index, icon: { _ in Data([1]) })
        let entry = try entry()
        fake.failNext = true
        spotlight.update(.init(server: "server", entries: [entry]))
        spotlight.update(.init(server: "server", entries: []))
        await spotlight.settle()
        #expect(fake.operations == [.clear])
        spotlight.update(.init(server: "server", entries: [entry]))
        await spotlight.settle()
        await spotlight.reindex([entry.id, "gone"])
        #expect(fake.operations.suffix(2) == [.remove(["gone"]), .add([entry.id])])
        await spotlight.reindex(nil)
        #expect(fake.operations.suffix(2) == [.clear, .add([entry.id])])
        #expect(fake.added.allSatisfy { $0.thumbnail == Data([1]) })
    }

    @Test func renamedChannelsAndChangedAvatarsReindexWithoutReaddingUnchangedRequests() async throws {
        let fake = FakeRequestIndex()
        var renders = 0
        let spotlight = RequestSpotlight(index: fake.index, icon: { _ in renders += 1; return Data([1]) })
        let entry = try entry()
        spotlight.update(.init(server: "server", entries: [entry]))
        await spotlight.settle()
        spotlight.update(.init(server: "server", entries: [entry]))
        await spotlight.settle()
        #expect(fake.operations.count == 2 && renders == 1)
        var renamed = item()
        renamed.name = "Workshop"
        let nameChange = try #require(WaitingRequestEntry(item: renamed, serverURL: "https://server.test"))
        spotlight.update(.init(server: "server", entries: [nameChange]))
        await spotlight.settle()
        #expect(fake.operations.last == .add([entry.id]) && renders == 1)
        renamed.agent?.avatar?.color = "#008800"
        let avatarChange = try #require(WaitingRequestEntry(item: renamed, serverURL: "https://server.test"))
        spotlight.update(.init(server: "server", entries: [avatarChange]))
        await spotlight.settle()
        #expect(fake.operations.last == .add([entry.id]) && renders == 2)
    }

    @Test func validationAndSessionLaunchesCannotTouchEitherSpotlightIndex() {
        #expect(!ChannelSpotlight.indexes(.init(), bundleID: "dev.toybox.desktop.test", environment: [:]))
        #expect(!ChannelSpotlight.indexes(.init(), bundleID: "dev.toybox.desktop.benchmark", environment: [:]))
        var options = LaunchOptions()
        options.quickSendValidation = .trace
        #expect(!ChannelSpotlight.indexes(options, bundleID: "dev.toybox.desktop", environment: [:]))
        options = .init()
        options.serverURL = "http://127.0.0.1:3210"
        #expect(!ChannelSpotlight.indexes(options, bundleID: "dev.toybox.desktop", environment: [:]))
        options = .init()
        options.snapshotURL = URL(filePath: "/tmp/spotlight.png")
        #expect(!ChannelSpotlight.indexes(options, bundleID: "dev.toybox.desktop", environment: [:]))
        #expect(!ChannelSpotlight.indexes(.init(), bundleID: "dev.toybox.desktop",
                                         environment: ["TOY_BOX_SERVER_URL": "https://server.test"]))
    }

    @Test func openRevealsExactlyTheOriginalRequestAndRejectsAnsweredOrOtherServerResults() async throws {
        let fixture = try RequestIntentFixture(entry: entry())
        try await fixture.context.openRequest(fixture.entry)
        #expect(fixture.opened == ["studio:8"])
        fixture.entries = []
        await #expect(throws: ChannelIntentError.requestNotWaiting) {
            try await fixture.context.openRequest(fixture.entry)
        }
        fixture.api = try ChannelAPI(serverURL: "https://other.test")
        await #expect(throws: ChannelIntentError.differentServer) {
            try await fixture.context.openRequest(fixture.entry)
        }
        #expect(fixture.opened == ["studio:8"])
    }

    @Test func replyConfirmsOncePostsOneCallerOwnedIDAndNeverOpensAWindow() async throws {
        let fixture = try RequestIntentFixture(entry: entry())
        try await fixture.context.replyToRequest(fixture.entry, message: "  Ship it. \n", id: "owned-id") { _ in }
        let posts = RequestPostProtocol.posts.withLock { $0 }
        #expect(posts == [.init(id: "owned-id", content: "@lead Ship it.")])
        #expect(fixture.confirmations == [.init(channel: "Studio", message: "Ship it.", recipient: "Lead")])
        #expect(fixture.opened.isEmpty && fixture.acquired == 1 && fixture.released == 1)
        #expect(fixture.store.sendAttempts.isEmpty)
        #expect(fixture.store.messages.contains { $0.id == "owned-id" && $0.sender == .user })
    }

    @Test func replyRechecksTheRequestAndServerAfterConfirmation() async throws {
        let fixture = try RequestIntentFixture(entry: entry())
        fixture.onConfirm = {
            var state = try #require(fixture.store.state)
            state.channel.requestSequence = 9
            _ = try fixture.store.apply(.init(type: "snapshot", state: state))
        }
        await #expect(throws: ChannelIntentError.requestNotWaiting) {
            try await fixture.context.replyToRequest(fixture.entry, message: "Hi", id: "changed") { _ in }
        }
        #expect(RequestPostProtocol.posts.withLock { $0 }.isEmpty)
        fixture.onConfirm = { fixture.api = try ChannelAPI(serverURL: "https://other.test") }
        var state = try #require(fixture.store.state)
        state.channel.requestSequence = 8
        _ = try fixture.store.apply(.init(type: "snapshot", state: state))
        await #expect(throws: ChannelIntentError.differentServer) {
            try await fixture.context.replyToRequest(fixture.entry, message: "Hi", id: "server") { _ in }
        }
        #expect(RequestPostProtocol.posts.withLock { $0 }.isEmpty)
    }

    @Test func declinedStaleAndEmptyRepliesNeverPost() async throws {
        let fixture = try RequestIntentFixture(entry: entry())
        fixture.onConfirm = { throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await fixture.context.replyToRequest(fixture.entry, message: "Hi", id: "declined") { _ in }
        }
        await #expect(throws: ChannelIntentError.emptyMessage) {
            try await fixture.context.replyToRequest(fixture.entry, message: " \n ", id: "empty") { _ in }
        }
        var state = try #require(fixture.store.state)
        state.channel.requestSequence = nil
        _ = try fixture.store.apply(.init(type: "snapshot", state: state))
        await #expect(throws: ChannelIntentError.requestNotWaiting) {
            try await fixture.context.replyToRequest(fixture.entry, message: "Hi", id: "stale") { _ in }
        }
        #expect(fixture.confirmations.count == 1 && RequestPostProtocol.posts.withLock { $0 }.isEmpty)
    }

    @Test func replyUsesTheCurrentCanonicalRequesterAndRejectsRenameDuringConfirmation() async throws {
        let fixture = try RequestIntentFixture(entry: entry())
        var state = try #require(fixture.store.state)
        state.lead.name = "Design Lead"
        _ = try fixture.store.apply(.init(type: "snapshot", state: state))
        fixture.onConfirm = {
            var updated = try #require(fixture.store.state)
            updated.lead.name = "New Name"
            _ = try fixture.store.apply(.init(type: "snapshot", state: updated))
        }
        await #expect(throws: ChannelIntentError.requestNotWaiting) {
            try await fixture.context.replyToRequest(fixture.entry, message: "Hi", id: "renamed") { _ in }
        }
        #expect(fixture.confirmations.first?.recipient == "Design Lead")
        #expect(RequestPostProtocol.posts.withLock { $0 }.isEmpty)
        fixture.onConfirm = {}
        try await fixture.context.replyToRequest(fixture.entry, message: "Hello", id: "current") { _ in }
        #expect(RequestPostProtocol.posts.withLock { $0.last?.content } == "@new-name Hello")
    }

    @Test(arguments: [422, 503])
    func failedRepliesStayInTheOutboxWithoutAnAutomaticSecondAttempt(status: Int) async throws {
        let fixture = try RequestIntentFixture(entry: entry())
        RequestPostProtocol.status.withLock { $0 = status }
        let expected: ChannelIntentError = status == 422 ? .waitingToSend("Studio") : .notConfirmed("Studio")
        for _ in 0..<2 {
            await #expect(throws: expected) {
                try await fixture.context.replyToRequest(fixture.entry, message: "Hi", id: "same-id") { _ in }
            }
        }
        #expect(RequestPostProtocol.posts.withLock { $0.count } == 1)
        #expect(fixture.store.sendAttempts.first?.id == "same-id")
        #expect(fixture.store.sendAttempts.first?.phase == (status == 422 ? .notSent : .deliveryNotConfirmed))
        #expect(fixture.confirmations.count == 1 && fixture.opened.isEmpty)
    }

    private func item(sequence: Int = 8) -> MenuBarStatus.Item {
        .init(id: "studio", name: "Studio", subtitle: "Lead needs your reply",
              agent: .init(id: "lead", name: "Lead",
                           avatar: .init(mark: "M4 4L20 20M4 20L20 4", color: "#0891b2")),
              sequence: sequence, quote: "Should we ship the caf\u{00e9} layout?", requestedAt: .distantPast)
    }

    private func entry(server: String = "https://server.test", sequence: Int = 8) throws -> WaitingRequestEntry {
        try #require(WaitingRequestEntry(item: item(sequence: sequence), serverURL: server))
    }
}

@MainActor
private final class FakeRequestIndex {
    enum Operation: Equatable { case clear, add([String]), remove([String]) }
    var operations: [Operation] = []
    var added: [WaitingRequestEntity] = []
    var failNext = false
    var index: RequestSpotlight.Index {
        .init(add: { try await self.record(.add($0.map(\.id)), entities: $0) },
              remove: { try await self.record(.remove($0)) },
              removeAll: { try await self.record(.clear) })
    }

    private func record(_ operation: Operation, entities: [WaitingRequestEntity] = []) throws {
        if failNext { failNext = false; throw ChannelAPIError.invalidResponse }
        operations.append(operation)
        added += entities
    }
}

@MainActor
private final class RequestIntentFixture {
    var api: ChannelAPI?
    let store: ChannelStore
    let entry: WaitingRequestEntry
    var entries: [WaitingRequestEntry]
    var opened: [String] = []
    var acquired = 0
    var released = 0
    var confirmations: [ChannelIntentsContext.SendConfirmation] = []
    var onConfirm: () throws -> Void = {}
    lazy var context: ChannelIntentsContext = {
        let context = ChannelIntentsContext(host: .init(
            api: { self.api }, store: { _ in self.store },
            acquire: { _ in self.acquired += 1 }, release: { _ in self.released += 1 },
            open: { _ in Issue.record("Reply must not open a window") },
            requests: { self.entries }, revealRequest: { self.opened.append("\($0):\($1)") }
        ))
        context.confirmationOverride = { prompt in
            self.confirmations.append(prompt)
            try self.onConfirm()
        }
        return context
    }()

    init(entry: WaitingRequestEntry) throws {
        self.entry = entry
        entries = [entry]
        RequestPostProtocol.posts.withLock { $0 = [] }
        RequestPostProtocol.status.withLock { $0 = 201 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestPostProtocol.self]
        let api = try ChannelAPI(serverURL: entry.link.serverURL, session: URLSession(configuration: configuration))
        self.api = api
        store = ChannelStore(id: entry.link.channelID, api: api, sendJournal: nil)
        let request = ChannelMessage(id: "request", sequence: entry.link.sequence, timestamp: "2026-10-24T12:00:00Z",
                                     sender: .agent(entry.agent.id), content: .text(entry.question), request: true)
        let channel = Channel(id: entry.link.channelID, name: entry.channelName,
                              model: .init(provider: "test", name: "test"), latestSequence: entry.link.sequence,
                              requestSequence: entry.link.sequence, updatedAt: request.timestamp)
        _ = try store.apply(.init(type: "snapshot", state: .init(revision: 1, channel: channel, lead: entry.agent,
                                                                messages: [request], request: request)))
    }
}

private final class RequestPostProtocol: URLProtocol, @unchecked Sendable {
    struct Posted: Codable, Sendable, Equatable { let id: String; let content: String }
    private struct Envelope: Encodable { let version = 1; let message: ChannelMessage }
    static let posts = Mutex<[Posted]>([])
    static let status = Mutex(201)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            #expect(request.httpMethod == "POST")
            let url = try #require(request.url)
            let data: Data
            if let body = request.httpBody { data = body }
            else {
                let stream = try #require(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw ChannelAPIError.invalidResponse }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                data = body
            }
            let posted = try JSONDecoder().decode(Posted.self, from: data)
            Self.posts.withLock { $0.append(posted) }
            let status = Self.status.withLock { $0 }
            let responseData = status == 201 ? try JSONEncoder().encode(Envelope(
                message: .init(id: posted.id, sequence: 10, timestamp: "2026-10-24T12:01:00Z",
                               sender: .user, content: .text(posted.content))
            )) : Data(#"{"error":"Rejected"}"#.utf8)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                        headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}
