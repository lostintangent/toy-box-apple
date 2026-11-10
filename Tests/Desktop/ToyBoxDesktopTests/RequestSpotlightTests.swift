import AppIntents
import AppKit
@testable import ChannelClient
import ChannelKit
import Foundation
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
        #expect(try self.entry(sequence: 9).id != entry.id)
        #expect(WaitingRequestQuery.matching("CAFE", in: [entity]).count == 1)
        #expect(WaitingRequestQuery.matching("studio", in: [entity]).count == 1)
        #expect(WaitingRequestQuery.matching("Lead", in: [entity]).count == 1)
        #expect(WaitingRequestQuery.matching("missing", in: [entity]).isEmpty)
    }

    @Test func requestsWithoutARequesterOrWordsAreLeftOut() throws {
        let healthy = item()
        var removedRequester = item(sequence: 9)
        removedRequester.agent = nil
        var unquoted = item(sequence: 11)
        unquoted.quote = nil
        let entries = [healthy, removedRequester, unquoted].compactMap {
            WaitingRequestEntry(item: $0)
        }
        #expect(entries.map(\.id) == [try entry().id])
    }

    @Test func anUnreachableServerThrows() async throws {
        let fixture = try RequestIntentFixture(entry: entry())
        fixture.isUnreachable = true
        await #expect(throws: ChannelIntentError.unreachable) { try await fixture.context.waitingRequests() }
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
        let nameChange = try #require(WaitingRequestEntry(item: renamed))
        spotlight.update(.init(server: "server", entries: [nameChange]))
        await spotlight.settle()
        #expect(fake.operations.last == .add([entry.id]) && renders == 1)
        renamed.agent?.avatar?.color = "#008800"
        let avatarChange = try #require(WaitingRequestEntry(item: renamed))
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
        options.servers = ["http://127.0.0.1:3210"]
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

    @Test func replyConfirmsOnceThenSavesOneMentionWithoutConnectingOrOpening() async throws {
        let fixture = try RequestIntentFixture(entry: entry())
        try await fixture.context.replyToRequest(fixture.entry, message: "  Ship it. \n") { _ in }
        let server = try #require(URL(string: "https://server.test"))
        #expect(fixture.sent == [.init(text: "@lead Ship it.", channelID: "studio", server: server, request: 8)])
        #expect(fixture.confirmations == [.init(channel: "Studio", message: "Ship it.", recipient: "Lead")])
        #expect(fixture.opened.isEmpty)
    }

    @Test func replyRechecksTheRequestAndServerAfterConfirmation() async throws {
        let fixture = try RequestIntentFixture(entry: entry())
        let replacement = try entry(sequence: 9)
        fixture.onConfirm = { fixture.entries = [replacement] }
        await #expect(throws: ChannelIntentError.requestNotWaiting) {
            try await fixture.context.replyToRequest(fixture.entry, message: "Hi") { _ in }
        }
        fixture.entries = [fixture.entry]
        fixture.onConfirm = { fixture.api = try ChannelAPI(serverURL: "https://other.test") }
        await #expect(throws: ChannelIntentError.differentServer) {
            try await fixture.context.replyToRequest(fixture.entry, message: "Hi") { _ in }
        }
        #expect(fixture.sent.isEmpty)
    }

    @Test func declinedStaleAndEmptyRepliesNeverSave() async throws {
        let fixture = try RequestIntentFixture(entry: entry())
        fixture.onConfirm = { throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await fixture.context.replyToRequest(fixture.entry, message: "Hi") { _ in }
        }
        await #expect(throws: ChannelIntentError.emptyMessage) {
            try await fixture.context.replyToRequest(fixture.entry, message: " \n ") { _ in }
        }
        fixture.entries = []
        await #expect(throws: ChannelIntentError.requestNotWaiting) {
            try await fixture.context.replyToRequest(fixture.entry, message: "Hi") { _ in }
        }
        #expect(fixture.confirmations.count == 1 && fixture.sent.isEmpty)
    }

    @Test func replyUsesTheCurrentRequesterAndRejectsRenameDuringConfirmation() async throws {
        let fixture = try RequestIntentFixture(entry: entry())
        fixture.entries = [try entry(agentName: "Design Lead")]
        let renamed = try entry(agentName: "New Name")
        fixture.onConfirm = { fixture.entries = [renamed] }
        await #expect(throws: ChannelIntentError.requestNotWaiting) {
            try await fixture.context.replyToRequest(fixture.entry, message: "Hi") { _ in }
        }
        #expect(fixture.confirmations.first?.recipient == "Design Lead")
        #expect(fixture.sent.isEmpty)
        fixture.onConfirm = {}
        try await fixture.context.replyToRequest(fixture.entry, message: "Hello") { _ in }
        #expect(fixture.sent.map(\.text) == ["@new-name Hello"])
    }

    private func item(server: String = "https://server.test", sequence: Int = 8,
                      agentName: String = "Lead") -> MenuBarStatus.Item {
        .init(target: ChannelTarget(serverURL: server, channelID: "studio")!, name: "Studio",
              subtitle: "Lead needs your reply",
              agent: .init(id: "lead", name: agentName,
                           avatar: .init(mark: "M4 4L20 20M4 20L20 4", color: "#0891b2")),
              sequence: sequence, quote: "Should we ship the caf\u{00e9} layout?", requestedAt: .distantPast)
    }

    private func entry(server: String = "https://server.test", sequence: Int = 8,
                       agentName: String = "Lead") throws -> WaitingRequestEntry {
        try #require(WaitingRequestEntry(item: item(server: server, sequence: sequence, agentName: agentName)))
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
    let entry: WaitingRequestEntry
    var entries: [WaitingRequestEntry]
    var isUnreachable = false
    var opened: [String] = []
    var sent: [ChannelIntents.Outgoing] = []
    var confirmations: [ChannelIntents.SendConfirmation] = []
    var onConfirm: () throws -> Void = {}
    lazy var context: ChannelIntents = {
        let context = ChannelIntents(host: .init(
            api: { self.api },
            channels: { Issue.record("A reply reads the waiting request, not the channel list"); return nil },
            store: { _ in Issue.record("A reply never connects its channel"); return nil },
            hold: { _ in }, release: { _ in },
            send: { self.sent.append($0) },
            open: { _ in Issue.record("Reply must not open a window") },
            requests: {
                if self.isUnreachable { throw ChannelIntentError.unreachable }
                return self.entries
            },
            revealRequest: { self.opened.append("\($0):\($1)") }
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
        api = try ChannelAPI(serverURL: entry.link.serverURL)
    }
}
