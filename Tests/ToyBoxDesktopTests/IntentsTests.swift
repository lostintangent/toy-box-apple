import AppIntents
import ChannelClient
import ChannelIntelligence
import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ToyBoxDesktop

/// Setting an intent's `@AppDependency` registers it in the shared manager, so every intent sees the
/// context set last. These tests run one at a time, and each installs its own.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct IntentsTests {
    // MARK: Entity and query

    @Test func entityMirrorsTheSidebar() {
        let waiting = ChannelEntity(channel("a", "Studio demo", latest: 15, seen: 9, request: 15))
        #expect(waiting.name == "Studio demo" && waiting.unreadCount == 6)
        #expect(waiting.needsReply && !waiting.tasksCompleted)
        #expect(subtitle(waiting) == "Needs your reply")

        let finished = ChannelEntity(channel("b", "Docs", latest: 5, seen: 3, completed: 5))
        #expect(finished.tasksCompleted && !finished.needsReply)
        #expect(subtitle(finished) == "All tasks completed")

        #expect(subtitle(ChannelEntity(channel("c", "Notes", latest: 5, seen: 3))) == "Unread messages")
        let quiet = ChannelEntity(channel("d", "Quiet", latest: 4, seen: 4))
        #expect(quiet.unreadCount == 0 && quiet.attention == nil && subtitle(quiet) == nil)
    }

    @Test func channelsMatchByNameIgnoringCaseAccentsAndPunctuation() {
        let entities = [
            channel("1", "Café ideas"), channel("2", "Studio demo"), channel("3", "Demo studio"),
            channel("4", "studio-demo-2"),
        ].map(ChannelEntity.init)
        #expect(ChannelQuery.matching("STUDIO-DEMO", in: entities).map(\.id) == ["2", "4"])
        #expect(ChannelQuery.matching("demo", in: entities).map(\.id) == ["3", "2", "4"])
        #expect(ChannelQuery.matching("cafe", in: entities).map(\.id) == ["1"])
        #expect(ChannelQuery.matching("  ", in: entities).count == 4)
        #expect(ChannelQuery.matching("roadmap", in: entities).isEmpty)
    }

    // MARK: Catch Me Up answers

    @Test func channelsThatNeedYouComeInTheSidebarsOrderOfUrgency() {
        let channels = [
            channel("quiet", "Quiet", latest: 4, seen: 4),
            channel("older", "Older", latest: 6, seen: 2, updatedAt: "2026-01-01T00:00:00.000Z"),
            channel("newer", "Newer", latest: 6, seen: 2, updatedAt: "2026-02-01T00:00:00.000Z"),
            channel("done", "Done", latest: 6, seen: 2, completed: 6),
            channel("ask", "Ask", latest: 6, seen: 6, request: 6),
        ]
        #expect(CatchUpAnswer.needingAttention(channels).map(\.id) == ["ask", "done", "newer", "older"])
    }

    @Test func overviewNamesTheFirstFewChannels() {
        let needing = CatchUpAnswer.needingAttention([
            channel("ask", "Studio demo", latest: 15, seen: 9, request: 15),
            channel("done", "Docs", latest: 6, seen: 2, completed: 6),
            channel("design", "Design", latest: 9, seen: 2, updatedAt: "2026-03-01T00:00:00.000Z"),
            channel("ops", "Ops", latest: 9, seen: 2),
        ])
        #expect(CatchUpAnswer.overview(needing, newMessages: ["design": 3]) == """
            You have updates in 4 channels. Studio demo is waiting for your reply. All tasks are completed \
            in Docs. Design has 3 new messages. There's 1 more channel with updates.
            """)
        #expect(CatchUpAnswer.overview(Array(needing.suffix(2)), newMessages: ["design": 0]) == """
            You have updates in 2 channels. Design has updates. Ops has new messages.
            """)
        #expect(CatchUpAnswer.overview(Array(needing.prefix(1)), newMessages: [:]) == "Studio demo is waiting for your reply.")
        #expect(CatchUpAnswer.overview([], newMessages: [:]) == "You're all caught up.")
    }

    @Test func requestThenShortMessagesInTheirOwnWords() {
        let state = state(channel("studio-demo", "Studio demo", latest: 15, seen: 9, request: 15), [
            message(9, from: "ada", "Earlier, already read."),
            event(11),
            message(12, from: "ada", "@moss Please review the **handoff**."),
            message(15, from: "lead", "Where should the shared library sit?", request: true),
        ])
        #expect(answer(state) == """
            Lead needs your reply in Studio demo: \u{201C}Where should the shared library sit?\u{201D} \
            There's also 1 new message. Ada wrote: \u{201C}Please review the handoff.\u{201D}
            """)
    }

    @Test func shortMessagesWithoutARequest() {
        let state = state(channel("c", "Design", latest: 4, seen: 1), [
            message(2, from: "ada", "Shipped the icons."),
            message(3, from: "moss", "", images: 1),
            message(4, from: "moss", "Looks right", images: 2),
        ])
        #expect(answer(state) == """
            There are 3 new messages in Design. Ada wrote: \u{201C}Shipped the icons.\u{201D} Moss shared an \
            image. Moss shared 2 images and wrote: \u{201C}Looks right\u{201D}
            """)
    }

    @Test func manyMessagesAreCountedWithTheirAuthors() {
        let senders = ["ada", "moss", "finch", "iris", "ada", "moss", "finch", "iris", "kit", "moss", "finch", "iris"]
        let messages = senders.enumerated().map { message(30 + $0.offset, from: $0.element, "Update \($0.offset).") }
        let state = state(channel("c", "Design", latest: 41, seen: 20), messages)
        #expect(answer(state, unreadAfter: 20) == """
            There are at least 12 new messages in Design, from Iris, Finch, Moss and 2 others.
            """)
        #expect(answer(state, unreadAfter: 29).hasPrefix("There are 12 new messages in Design, from"))
    }

    @Test func modelSummaryLeadsWhenReady() {
        let state = state(channel("studio-demo", "Studio demo", latest: 15, seen: 9, completed: 14, request: 15), [
            message(15, from: "lead", "Where should the shared library sit?", request: true),
        ])
        let summary = CatchUp(needsYou: .init(text: "Lead asked you to choose where the library sits.", sources: [15]),
                              changes: [.init(text: "Ada finished the handoff.", sources: [12])], through: 15)
        #expect(answer(state, summary: (summary, 6)) == """
            Here's a summary of 6 new messages in Studio demo. Lead asked you to choose where the library \
            sits. Ada finished the handoff. All tasks are completed.
            """)

        let noAsk = CatchUp(needsYou: nil, changes: [.init(text: "All tasks were completed.", sources: [14])], through: 15)
        #expect(answer(state, summary: (noAsk, 1)) == """
            Here's a summary of 1 new message in Studio demo. Lead needs your reply: \u{201C}Where should the \
            shared library sit?\u{201D} All tasks were completed.
            """)
    }

    @Test func quietChannels() {
        let done = state(channel("c", "Docs", latest: 10, seen: 9, completed: 10), [event(10)])
        #expect(answer(done) == "All tasks are completed in Docs.")
        let events = state(channel("c", "Docs", latest: 10, seen: 9), [event(10)])
        #expect(answer(events) == "There are no new messages in Docs.")
        let read = state(channel("c", "Docs", latest: 10, seen: 10), [message(10, from: "ada", "Done.")])
        #expect(answer(read, unreadAfter: nil) == "You're all caught up in Docs.")
    }

    @Test func namesAreListedTheWaySiriSpeaksThem() {
        #expect(CatchUpAnswer.list(["Ada"]) == "Ada")
        #expect(CatchUpAnswer.list(["Ada", "Moss"]) == "Ada and Moss")
        #expect(CatchUpAnswer.list(["Ada", "Moss", "Kit"]) == "Ada, Moss and Kit")
        #expect(CatchUpAnswer.list(["Ada", "Moss", "Kit", "Iris"]) == "Ada, Moss, Kit and 1 other")
    }

    // MARK: Intents without a server

    @Test func everyIntentSaysWhenThereIsNoServer() async throws {
        let host = TestHost(api: nil)
        var catchUp = CatchMeUpIntent(channel: nil)
        catchUp.context = host.context
        await #expect(throws: ChannelIntentError.noServer) { try await catchUp.perform() }
        var query = ChannelQuery()
        query.context = host.context
        await #expect(throws: ChannelIntentError.noServer) { try await query.suggestedEntities() }
    }

    @Test func anEmptyMessageIsNeverConfirmedOrSent() async throws {
        let host = TestHost(api: nil)
        var intent = SendMessageIntent(channel: ChannelEntity(channel("c", "Docs")), message: " \n ")
        intent.context = host.context
        await #expect(throws: ChannelIntentError.emptyMessage) { try await intent.perform() }
        #expect(host.confirmations.isEmpty && host.acquired.isEmpty)
    }

    // MARK: Helpers

    private func subtitle(_ entity: ChannelEntity) -> String? {
        entity.displayRepresentation.subtitle.map { String(localized: $0) }
    }

    private func answer(_ state: ChannelState, unreadAfter: Int? = nil,
                        summary: (catchUp: CatchUp, count: Int)? = nil) -> String {
        let boundary = unreadAfter ?? channelUnreadAfter(state.channel)
        return CatchUpAnswer.channel(state.channel, unreadAfter: boundary,
                                     digest: CatchUpDigest(state: state, unreadAfter: boundary), summary: summary)
    }
}

// MARK: Demo server

extension IntentsTests {
    /// Calls each intent's `perform()` against a demo server, ideally a private one:
    /// `TOY_BOX_DEMO_PORT=3260 bun script/demo.mjs`, then
    /// `TOY_BOX_DEMO_URL=http://127.0.0.1:3260 ./script/test --filter IntentsTests`.
    @MainActor @Suite(.timeLimit(.minutes(1)))
    struct Demo {
        nonisolated static var demoURL: String? { ProcessInfo.processInfo.environment["TOY_BOX_DEMO_URL"] }

        @Test(.enabled(if: demoURL != nil))
        func queryFindsChannelsAndOpenRoutesThem() async throws {
            let host = try TestHost.demo()
            var query = ChannelQuery()
            query.context = host.context
            let suggested = try await query.suggestedEntities()
            let studio = try #require(suggested.first { $0.id == "studio-demo" })
            #expect(studio.name == "Studio demo")
            #expect(try await query.entities(matching: "studio demo").first?.id == "studio-demo")
            #expect(try await query.entities(for: ["studio-demo", "missing"]).map(\.id) == ["studio-demo"])

            var intent = OpenChannelIntent(target: studio)
            intent.context = host.context
            _ = try await intent.perform()
            #expect(host.opened == ["studio-demo"])
            #expect(host.acquired.isEmpty)
        }

        @Test(.enabled(if: demoURL != nil))
        func catchMeUpReadsAChannelWithoutMarkingIt() async throws {
            let host = try TestHost.demo()
            let channel = try #require(try await host.api?.catalog().channels.first { $0.id == "studio-demo" })
            RequestRecorder.reset()
            var intent = CatchMeUpIntent(channel: ChannelEntity(channel))
            intent.context = host.context
            let started = ContinuousClock.now
            let value = try #require(try await intent.perform().value)
            print("Catch Me Up (studio-demo, \(ContinuousClock.now - started)): \(value)")

            #expect(value.contains("Studio demo"))
            if channel.requestSequence != nil { #expect(value.hasPrefix("Lead needs your reply in Studio demo: \u{201C}")) }
            #expect(host.acquired == ["studio-demo"])
            #expect(host.store("studio-demo")?.phase == .idle)
            let requests = RequestRecorder.requests
            #expect(!requests.isEmpty && requests.allSatisfy { $0.hasPrefix("GET ") })
        }

        @Test(.enabled(if: demoURL != nil))
        func catchMeUpWithoutAChannelCoversEveryChannelThatNeedsYou() async throws {
            let host = try TestHost.demo()
            let api = try #require(host.api)
            let needing = CatchUpAnswer.needingAttention(try await api.catalog().channels)
            RequestRecorder.reset()
            var intent = CatchMeUpIntent(channel: nil)
            intent.context = host.context
            let value = try #require(try await intent.perform().value)
            print("Catch Me Up (all channels): \(value)")
            switch needing.count {
            case 0: #expect(value == "You're all caught up.")
            case 1: #expect(value.contains(needing[0].name) && !value.contains("channels"))
            default: #expect(value.hasPrefix("You have updates in \(needing.count) channels."))
            }
            #expect(RequestRecorder.requests.allSatisfy { $0.hasPrefix("GET ") })
        }

        @Test(.enabled(if: demoURL != nil))
        func sendMessageConfirmsThenPostsOnce() async throws {
            let host = try TestHost.demo()
            let api = try #require(host.api)
            let channel = try #require(try await api.catalog().channels.first { $0.id == "studio-demo" })
            let text = "Siri intent fixture \(UUID().uuidString.prefix(8))"
            RequestRecorder.reset()
            var intent = SendMessageIntent(channel: ChannelEntity(channel), message: "  \(text)\n")
            intent.context = host.context
            _ = try await intent.perform()

            #expect(host.confirmations == [.init(channel: "Studio demo", message: text)])
            #expect(RequestRecorder.requests.contains("POST /api/v1/channels/studio-demo/messages"))
            var snapshot = api.observe(channelId: "studio-demo").makeAsyncIterator()
            let state = try #require(try await snapshot.next()?.state)
            let posted = state.messages.filter { $0.text == text }
            #expect(posted.count == 1 && posted.first?.sender == .user)
            #expect(state.channel.latestSequence > channel.latestSequence)
            let store = try #require(host.store("studio-demo"))
            #expect(store.sendAttempts.allSatisfy { $0.phase == .confirmed })
            #expect(store.phase == .idle)
        }

        @Test(.enabled(if: demoURL != nil))
        func declinedConfirmationSendsNothing() async throws {
            let host = try TestHost.demo()
            let channel = try #require(try await host.api?.catalog().channels.first { $0.id == "studio-demo" })
            host.declines = true
            RequestRecorder.reset()
            var intent = SendMessageIntent(channel: ChannelEntity(channel), message: "Never sent")
            intent.context = host.context
            await #expect(throws: CancellationError.self) { try await intent.perform() }
            #expect(host.confirmations.count == 1 && host.acquired.isEmpty)
            #expect(!RequestRecorder.requests.contains { $0.hasPrefix("POST ") })
        }
    }
}

// MARK: Fixtures

@MainActor
private final class TestHost {
    let api: ChannelAPI?
    let journal = ChannelSendJournal(directory: FileManager.default.temporaryDirectory
        .appending(path: "IntentsTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    private var stores: [String: ChannelStore] = [:]
    private var holds: [String: Int] = [:]
    private(set) var acquired: [String] = []
    private(set) var opened: [String] = []
    private(set) var confirmations: [ChannelIntentsContext.SendConfirmation] = []
    var declines = false
    /// Installs a context backed by this host, which intents use until the next is installed.
    var context: ChannelIntentsContext {
        let context = ChannelIntentsContext(host: .init(
            api: { self.api },
            store: { self.store($0) },
            acquire: { store in
                self.acquired.append(store.id)
                self.holds[store.id, default: 0] += 1
                if self.holds[store.id] == 1 { store.connect() }
            },
            release: { store in
                self.holds[store.id, default: 1] -= 1
                if self.holds[store.id] == 0 { store.disconnect() }
            },
            open: { self.opened.append($0) }
        ), intelligence: UnavailableIntelligence(), summarizes: { false })
        context.confirmationOverride = { prompt in
            self.confirmations.append(prompt)
            if self.declines { throw CancellationError() }
        }
        AppDependencyManager.shared.add(dependency: context)
        return context
    }

    init(api: ChannelAPI?) {
        self.api = api
    }

    /// The demo server, through a session that records each request. Never the live server.
    static func demo() throws -> TestHost {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestRecorder.self] + (configuration.protocolClasses ?? [])
        let api = try ChannelAPI(serverURL: #require(IntentsTests.Demo.demoURL),
                                 session: URLSession(configuration: configuration))
        guard ["localhost", "127.0.0.1"].contains(api.baseURL.host), api.baseURL.port != 3100 else {
            throw ChannelAPIError.invalidServerURL
        }
        return TestHost(api: api)
    }

    func store(_ id: String) -> ChannelStore? {
        guard let api else { return nil }
        if let store = stores[id] { return store }
        let store = ChannelStore(id: id, api: api, sendJournal: journal)
        stores[id] = store
        return store
    }
}

/// Sees every request a session makes and lets the system load it.
private final class RequestRecorder: URLProtocol, @unchecked Sendable {
    private static let log = Mutex<[String]>([])
    static var requests: [String] { log.withLock { $0 } }
    static func reset() { log.withLock { $0 = [] } }

    override class func canInit(with request: URLRequest) -> Bool {
        let entry = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
        log.withLock { if $0.last != entry { $0.append(entry) } }
        return false
    }
}

private struct UnavailableIntelligence: ChannelIntelligenceService {
    var availability: IntelligenceAvailability { .unavailable(.modelNotReady) }
    func catchUp(_ request: CatchUpRequest) async -> CatchUpResult { .unavailable(.modelNotReady) }
    func altText(_ request: AltTextRequest) async -> AltText? { nil }
}

private func channel(_ id: String, _ name: String, latest: Int = 0, seen: Int = 0, completed: Int? = nil,
                     request: Int? = nil, updatedAt: String = "2026-01-15T00:00:00.000Z") -> Channel {
    Channel(id: id, name: name, model: .init(provider: "test", name: "test"), latestSequence: latest,
            seenThrough: seen, completedSequence: completed, requestSequence: request, updatedAt: updatedAt)
}

private func state(_ channel: Channel, _ messages: [ChannelMessage]) -> ChannelState {
    ChannelState(
        revision: 1, channel: channel, lead: .lead(id: "lead"),
        members: [
            .init(id: "ada", name: "Ada"), .init(id: "moss", name: "Moss"), .init(id: "finch", name: "Finch"),
            .init(id: "iris", name: "Iris"), .init(id: "kit", name: "Kit"),
        ],
        messages: messages,
        request: messages.last { $0.request == true }
    )
}

private func message(_ sequence: Int, from sender: String, _ text: String, request: Bool? = nil,
                     images: Int = 0) -> ChannelMessage {
    ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T10:00:00.000Z",
                   sender: .agent(sender), content: .text(text), request: request,
                   attachments: images == 0 ? nil : (0..<images).map { ChannelAttachment(name: "image-\($0).png") })
}

private func event(_ sequence: Int) -> ChannelMessage {
    ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T10:00:00.000Z",
                   sender: .system, content: .system(ChannelSystemContent(type: "tasks_completed")))
}
