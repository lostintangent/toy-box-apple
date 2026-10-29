import AppIntents
import AppKit
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

    // MARK: Spotlight

    @Test func spotlightGetsTheNameAndPurposeButNeverTheAttention() throws {
        let entity = ChannelEntity(channel("a", "Studio demo", purpose: "  Ship the demo  \nThen the docs",
                                           latest: 15, seen: 9, request: 15))
        #expect(entity.purpose == "Ship the demo" && subtitle(entity) == "Needs your reply")
        let attributes = entity.attributeSet
        #expect(attributes.displayName == "Studio demo" && attributes.title == "Studio demo")
        #expect(attributes.contentDescription == "Ship the demo" && attributes.thumbnailData == nil)

        let png = try #require(ChannelSpotlight.renderIcon())
        let quiet = ChannelEntity(id: "b", name: "Docs", attention: .unread, thumbnail: png).attributeSet
        #expect(quiet.contentDescription == nil && quiet.thumbnailData == png)

        let icon = try #require(NSBitmapImageRep(data: png))
        #expect(icon.pixelsWide == 128 && icon.pixelsHigh == 128)
    }

    @Test func onlyTheServerSavedInSettingsFillsSpotlight() {
        #expect(ChannelSpotlight.indexes(LaunchOptions(), bundleID: "dev.toybox.desktop", environment: [:]))
        var session = LaunchOptions()
        session.serverURL = "http://127.0.0.1:3210"
        #expect(!ChannelSpotlight.indexes(session, bundleID: "dev.toybox.desktop", environment: [:]))
        #expect(!ChannelSpotlight.indexes(LaunchOptions(), bundleID: "dev.toybox.desktop",
                                         environment: ["TOY_BOX_SERVER_URL": "http://127.0.0.1:3210"]))
        var snapshot = LaunchOptions()
        snapshot.snapshotURL = URL(filePath: "/tmp/snapshot.png")
        #expect(!ChannelSpotlight.indexes(snapshot, bundleID: "dev.toybox.desktop", environment: [:]))
    }

    @Test func requestQueryAndOpenOnlyResolveTheOriginalWaitingResult() async throws {
        let host = TestHost(api: try ChannelAPI(serverURL: "https://server.test"))
        let item = MenuBarStatus.Item(id: "studio", name: "Studio", subtitle: "Lead needs your reply",
                                     agent: .init(id: "lead", name: "Lead"), sequence: 8, quote: "Ship the layout?")
        let entry = try #require(WaitingRequestEntry(item: item, serverURL: "https://server.test"))
        let otherServer = try #require(WaitingRequestEntry(item: item, serverURL: "https://other.test"))
        host.waitingRequests = [entry]
        let context = host.context
        var query = WaitingRequestQuery()
        query.context = context
        #expect(try await query.entities(for: [entry.id, otherServer.id]).map(\.id) == [entry.id])
        #expect(try await query.entities(matching: "layout").map(\.id) == [entry.id])
        #expect(try await query.suggestedEntities().map(\.id) == [entry.id])
        #expect(try await query.allEntities().map(\.id) == [entry.id])
        var intent = OpenRequestIntent(target: WaitingRequestEntity(entry))
        intent.context = context
        _ = try await intent.perform()
        #expect(host.revealedRequests == ["studio:8"] && host.held.isEmpty)
        host.waitingRequests = []
        #expect(try await query.entities(for: [entry.id]).isEmpty)
        await #expect(throws: ChannelIntentError.requestNotWaiting) { try await intent.perform() }
        #expect(host.revealedRequests.count == 1)
    }

    @Test func spotlightKeepsAnEarlierLaunchsChannelsUntilTheCatalogReplacesThem() {
        typealias Spotlight = ChannelSpotlight
        let loading = Spotlight.plan(from: nil, to: .init(server: "s", channels: nil))
        #expect(loading.plan.isEmpty && loading.indexed == nil)

        let a = Spotlight.Entry(id: "a", name: "Studio demo"), b = Spotlight.Entry(id: "b", name: "Docs")
        let loaded = Spotlight.plan(from: nil, to: .init(server: "s", channels: [a, b, a]))
        #expect(loaded.plan == .init(removesAll: true, indexes: [a, b]))
        #expect(loaded.indexed == .init(server: "s", entries: ["a": a, "b": b]))

        let noServer = Spotlight.plan(from: nil, to: .init(server: nil, channels: nil))
        #expect(noServer.plan == .init(removesAll: true) && noServer.indexed == .init(server: nil, entries: [:]))
        #expect(Spotlight.plan(from: noServer.indexed, to: .init(server: nil, channels: nil)).plan.isEmpty)
    }

    @Test func spotlightFollowsRenamesAndDeletionsOnTheSameServer() {
        typealias Spotlight = ChannelSpotlight
        let a = Spotlight.Entry(id: "a", name: "Studio demo"), b = Spotlight.Entry(id: "b", name: "Docs")
        let c = Spotlight.Entry(id: "c", name: "Ops")
        let indexed = Spotlight.Indexed(server: "s", entries: ["a": a, "b": b, "c": c])
        let renamed = Spotlight.Entry(id: "b", name: "Handbook"), purpose = Spotlight.Entry(id: "a", name: "Studio demo", purpose: "Ship")
        let d = Spotlight.Entry(id: "d", name: "Design")
        let next = Spotlight.plan(from: indexed, to: .init(server: "s", channels: [purpose, renamed, d]))
        #expect(next.plan == .init(removes: ["c"], indexes: [purpose, renamed, d]))
        #expect(Spotlight.plan(from: next.indexed, to: .init(server: "s", channels: [purpose, renamed, d])).plan.isEmpty)
        // A catalog reloading for the same server keeps what's there.
        let reloading = Spotlight.plan(from: indexed, to: .init(server: "s", channels: nil))
        #expect(reloading.plan.isEmpty && reloading.indexed == indexed)
    }

    @Test func switchingServersEmptiesSpotlightAtOnce() {
        typealias Spotlight = ChannelSpotlight
        let a = Spotlight.Entry(id: "a", name: "Studio demo"), x = Spotlight.Entry(id: "x", name: "Roadmap")
        let switched = Spotlight.plan(from: .init(server: "one", entries: ["a": a]), to: .init(server: "two", channels: nil))
        #expect(switched.plan == .init(removesAll: true) && switched.indexed == .init(server: "two", entries: [:]))
        let loaded = Spotlight.plan(from: switched.indexed, to: .init(server: "two", channels: [x]))
        #expect(loaded.plan == .init(indexes: [x]))
        let gone = Spotlight.plan(from: loaded.indexed, to: .init(server: nil, channels: nil))
        #expect(gone.plan == .init(removesAll: true) && gone.indexed == .init(server: nil, entries: [:]))
    }

    @Test func spotlightAppliesChangesInOrderAndStartsOverAfterAFailure() async {
        let index = FakeSpotlightIndex()
        let spotlight = ChannelSpotlight(index: index.index, icon: { Data("icon".utf8) })
        let a = ChannelSpotlight.Entry(id: "a", name: "Studio demo", purpose: "Ship")
        let b = ChannelSpotlight.Entry(id: "b", name: "Docs")
        spotlight.update(.init(server: "s", channels: nil))
        spotlight.update(.init(server: "s", channels: [a, b]))
        spotlight.update(.init(server: "s", channels: [a]))
        await spotlight.settle()
        #expect(index.operations == ["remove all", "add a b", "remove b"])
        #expect(index.added.allSatisfy { $0.thumbnail == Data("icon".utf8) } && index.added.first?.purpose == "Ship")

        await spotlight.reindex(["a", "b"])
        #expect(index.operations.suffix(2) == ["remove b", "add a"])
        await spotlight.reindex()
        #expect(index.operations.suffix(2) == ["remove all", "add a"])

        index.fails = true
        spotlight.update(.init(server: "s", channels: [a, b]))
        await spotlight.settle()
        #expect(spotlight.indexed == nil)
        index.fails = false
        spotlight.update(.init(server: "s", channels: [a, b]))
        await spotlight.settle()
        #expect(index.operations.suffix(2) == ["remove all", "add a b"])
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
            You have updates in 4 channels. Studio demo is waiting for your reply. Docs finished all its \
            tasks. Design has 3 new messages. There's 1 more channel with updates.
            """)
        #expect(CatchUpAnswer.overview(Array(needing.suffix(2)), newMessages: ["design": 0]) == """
            You have updates in 2 channels. Design has new activity. Ops has new messages.
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
            sits. Ada finished the handoff. All tasks are done.
            """)

        let noAsk = CatchUp(needsYou: nil, changes: [.init(text: "All tasks were completed.", sources: [14])], through: 15)
        #expect(answer(state, summary: (noAsk, 1)) == """
            Here's a summary of 1 new message in Studio demo. Lead needs your reply: \u{201C}Where should the \
            shared library sit?\u{201D} All tasks were completed.
            """)
    }

    @Test func quietChannels() {
        let done = state(channel("c", "Docs", latest: 10, seen: 9, completed: 10), [event(10)])
        #expect(answer(done) == "Docs finished all its tasks.")
        let doneWithNote = state(channel("c", "Docs", latest: 11, seen: 9, completed: 10),
                                 [event(10), message(11, from: "ada", "Merged.")])
        #expect(answer(doneWithNote) == """
            There's 1 new message in Docs. Ada wrote: \u{201C}Merged.\u{201D} All tasks are done.
            """)
        let events = state(channel("c", "Docs", latest: 10, seen: 9), [event(10)])
        #expect(answer(events) == "There are no new messages in Docs.")
        let read = state(channel("c", "Docs", latest: 10, seen: 10), [message(10, from: "ada", "Done.")])
        #expect(answer(read, unreadAfter: nil) == "You're all caught up in Docs.")
    }

    // MARK: Catch Me Up cards

    @Test func cardShowsTheRequestAndNewMessagesInTheirOwnWords() throws {
        let asking = state(channel("studio-demo", "Studio demo", latest: 15, seen: 9, request: 15), [
            message(9, from: "ada", "Earlier, already read."),
            event(11),
            message(12, from: "ada", "@moss Please review the **handoff** with @iris and @everyone."),
            message(15, from: "lead", "Where should the shared library sit?", request: true),
        ])
        let answer = answerWithCard(asking)
        #expect(answer.headline == "Lead needs your reply in Studio demo.")
        #expect(answer.spoken.contains("Please review the handoff with Iris and everyone."))
        let card = try #require(answer.card)
        #expect(card.channelID == "studio-demo" && card.title == "Studio demo" && card.subtitle == "1 new message")
        #expect(card.caption == "Waiting for your reply \u{00B7} 1 new message")
        #expect(!card.isSummary && card.footnote == nil && !card.isReplied)
        #expect(card.lines.map(\.speaker) == ["Lead", "Ada"])
        #expect(card.lines.map(\.text) == ["Where should the shared library sit?",
                                            "Please review the handoff with @Iris and @everyone."])
        #expect(card.lines[0].mentions == nil && card.lines[1].mentions?.map(\.name) == ["Iris"])
        #expect(card.lines[0].slot == .request)
        guard case .agent(let ada) = card.lines[1].slot else { Issue.record("Ada's line has no avatar"); return }
        #expect(ada.id == "ada" && ada.name == "Ada" && ada.role == nil)
        #expect(card.reply == .init(recipient: "Lead", request: 15))

        var replied = card
        replied.isReplied = true
        #expect(replied.caption == "Replied \u{00B7} 1 new message")
        let askOnly = try #require(answerWithCard(state(channel("c", "Docs", latest: 15, seen: 14, request: 15), [
            message(15, from: "lead", "Ship it?", request: true),
        ])).card)
        #expect(askOnly.subtitle == nil && askOnly.caption == "Waiting for your reply")
    }

    @Test func cardShowsTheNewestFewOfManyMessages() throws {
        let senders = ["ada", "moss", "finch", "iris", "ada", "moss", "finch", "iris", "kit", "moss", "finch", "iris"]
        let messages = senders.enumerated().map { message(30 + $0.offset, from: $0.element, "Update \($0.offset).") }
        let many = state(channel("c", "Design", latest: 41, seen: 20), messages)

        let partial = answerWithCard(many, unreadAfter: 20)
        #expect(partial.headline == "There are at least 12 new messages in Design.")
        let card = try #require(partial.card)
        #expect(card.caption == "At least 12 new messages" && card.footnote == "Plus at least 9 earlier messages")
        #expect(card.lines.map(\.text) == ["Update 9.", "Update 10.", "Update 11."])
        #expect(card.lines.map(\.speaker) == ["Moss", "Finch", "Iris"] && card.reply == nil)

        let complete = answerWithCard(many, unreadAfter: 29)
        #expect(complete.headline == "There are 12 new messages in Design.")
        #expect(complete.card?.subtitle == "12 new messages" && complete.card?.footnote == "Plus 9 earlier messages")

        let one = answerWithCard(state(channel("c", "Design", latest: 4, seen: 3), [message(4, from: "moss", "", images: 2)]))
        #expect(one.headline == "There's 1 new message in Design.")
        #expect(one.card?.lines.map(\.text) == ["Moss shared 2 images."] && one.card?.lines.first?.speaker == nil)
    }

    @Test func cardShowsTheModelsSummaryWhenReady() throws {
        let state = state(channel("studio-demo", "Studio demo", latest: 15, seen: 9, completed: 14, request: 15), [
            message(12, from: "ada", "Handoff is in."),
            message(15, from: "lead", "Where should the shared library sit?", request: true),
        ])
        let summary = CatchUp(needsYou: .init(text: "Lead asked you to choose where the library sits.", sources: [15]),
                              changes: [.init(text: "Ada finished the handoff.", sources: [12]),
                                        .init(text: "The plan changed.", sources: [3])], through: 15)
        let answer = answerWithCard(state, summary: (summary, 6))
        #expect(answer.headline == "Here's a summary of 6 new messages in Studio demo.")
        let card = try #require(answer.card)
        #expect(card.isSummary && card.caption == "Summary of 6 new messages")
        #expect(card.footnote == "Summarized on this Mac" && card.reply == .init(recipient: "Lead", request: 15))
        #expect(card.lines.map(\.text) == ["Lead asked you to choose where the library sits.", "Ada finished the handoff.",
                                            "The plan changed.", "All tasks completed"])
        #expect(card.lines.allSatisfy { $0.speaker == nil })
        #expect(card.lines[0].slot == .request && card.lines[2].slot == .info)
        #expect(card.lines[3].slot == .event("tasks_completed"))
    }

    @Test func quietChannelsHaveNoCard() {
        let events = state(channel("c", "Docs", latest: 10, seen: 9), [event(10)])
        #expect(answerWithCard(events).card == nil)
        let read = state(channel("c", "Docs", latest: 10, seen: 10), [message(10, from: "ada", "Done.")])
        #expect(answerWithCard(read, unreadAfter: nil).card == nil)

        let done = answerWithCard(state(channel("c", "Docs", latest: 10, seen: 9, completed: 10), [event(10)]))
        #expect(done.headline == "Docs finished all its tasks.")
        #expect(done.card?.caption == "All tasks completed" && done.card?.lines == [])
        #expect(CatchUpAnswer.overviewAnswer([], newMessages: [:]) == .init(spoken: "You're all caught up."))
    }

    @Test func overviewCardListsChannelsWithTheSidebarsIndicators() throws {
        let needing = CatchUpAnswer.needingAttention([
            channel("ask", "Studio demo", latest: 15, seen: 9, request: 15),
            channel("done", "Docs", latest: 6, seen: 2, completed: 6),
            channel("design", "Design", latest: 9, seen: 2, updatedAt: "2026-03-01T00:00:00.000Z"),
            channel("ops", "Ops", latest: 9, seen: 2, updatedAt: "2026-02-01T00:00:00.000Z"),
            channel("notes", "Notes", latest: 9, seen: 2, updatedAt: "2026-01-20T00:00:00.000Z"),
            channel("misc", "Misc", latest: 9, seen: 2),
            channel("old", "Old", latest: 9, seen: 2, updatedAt: "2025-01-01T00:00:00.000Z"),
        ])
        let answer = CatchUpAnswer.overviewAnswer(needing, newMessages: ["design": 3, "ops": 0])
        #expect(answer.spoken.hasPrefix("You have updates in 7 channels. Studio demo is waiting for your reply."))
        #expect(answer.headline == "You have updates in 7 channels.")
        let card = try #require(answer.card)
        #expect(card.channelID == nil && card.title == "Updates in 7 channels" && card.reply == nil)
        #expect(card.rows.map(\.name) == ["Studio demo", "Docs", "Design", "Ops", "Notes"])
        #expect(card.rows.map(\.attention) == ["waiting", "finished", "unread", "unread", "unread"])
        #expect(card.rows.map(\.detail) == ["Waiting for your reply", "Finished all its tasks", "3 new messages",
                                             "New activity", "New messages"])
        #expect(card.footnote == "Plus 2 more channels")
    }

    @Test func cardSurvivesTheTripThroughItsSnippetIntent() throws {
        let state = state(channel("studio-demo", "Studio demo", latest: 15, seen: 9, request: 15), [
            message(12, from: "ada", "Handoff is in."),
            message(15, from: "lead", "Where should the shared library sit?", request: true),
        ])
        let card = try #require(answerWithCard(state).card)
        #expect(CatchUpCard(encoded: CatchUpSnippetIntent(card: card).card) == card)
        #expect(CatchUpCard(encoded: "not a card") == nil)

        let context = TestHost(api: nil).context
        #expect(!context.withReplies(card).isReplied)
    }

    @Test func aReplyConfirmsWithItsRecipientAndMentionsThem() {
        let prompt = ChannelIntentsContext.SendConfirmation(channel: "Studio demo", message: "Next to the app.",
                                                            recipient: "Lead")
        #expect(prompt.question == "Send \u{201C}Next to the app.\u{201D} to Lead in Studio demo?")
        #expect(ChannelIntentsContext.SendConfirmation(channel: "Docs", message: "Hi").question
            == "Send \u{201C}Hi\u{201D} to Docs?")
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

    @Test func aReplyWithoutAServerIsNeverConfirmed() async throws {
        let host = TestHost(api: nil)
        var intent = ReplyIntent(channel: ChannelEntity(id: "c", name: "Docs"), recipient: "Lead", request: 4,
                                 message: "Sounds good")
        intent.context = host.context
        await #expect(throws: ChannelIntentError.noServer) { try await intent.perform() }
        #expect(host.confirmations.isEmpty && host.held.isEmpty)
    }

    @Test func anEmptyMessageIsNeverConfirmedOrSent() async throws {
        let host = TestHost(api: nil)
        var intent = SendMessageIntent(channel: ChannelEntity(channel("c", "Docs")), message: " \n ")
        intent.context = host.context
        await #expect(throws: ChannelIntentError.emptyMessage) { try await intent.perform() }
        #expect(host.confirmations.isEmpty && host.held.isEmpty)
    }

    // MARK: Helpers

    private func subtitle(_ entity: ChannelEntity) -> String? {
        entity.displayRepresentation.subtitle.map { String(localized: $0) }
    }

    private func answerWithCard(_ state: ChannelState, unreadAfter: Int? = nil,
                                summary: (catchUp: CatchUp, count: Int)? = nil) -> CatchUpAnswer.Answer {
        let boundary = unreadAfter ?? channelUnreadAfter(state.channel)
        let answer = CatchUpAnswer.channelAnswer(state, unreadAfter: boundary,
                                                 digest: CatchUpDigest(state: state, unreadAfter: boundary), summary: summary)
        #expect(answer.spoken == self.answer(state, unreadAfter: unreadAfter, summary: summary))
        return answer
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
    /// `TOY_BOX_DEMO_PORT=3260 bun run demo`, then
    /// `TOY_BOX_DEMO_URL=http://127.0.0.1:3260 bun run test --filter IntentsTests`.
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
            #expect(host.held.isEmpty)
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
            #expect(host.held == ["studio-demo"])
            #expect(host.holds["studio-demo"] == 0, "The intent released the channel it held")
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

        /// Runs before any other test posts, which would answer the demo's request.
        @Test(.enabled(if: demoURL != nil))
        func cardReplyMentionsWhoAskedAndTurnsTheCardToReplied() async throws {
            let host = try TestHost.demo()
            let api = try #require(host.api)
            let channel = try #require(try await api.catalog().channels.first { $0.id == "studio-demo" })
            let context = host.context
            let answer = try await context.catchUp(channelID: "studio-demo")
            let card = try #require(answer.card)
            let reply = card.reply
            let recipient = reply?.recipient
            print("Catch Me Up card (studio-demo, \(card.encoded.utf8.count) bytes, reply to \(recipient ?? "nobody")): \(answer.headline)")
            #expect(!context.withReplies(card).isReplied)

            let text = "Siri reply fixture \(UUID().uuidString.prefix(8))"
            RequestRecorder.reset()
            var intent = ReplyIntent(channel: ChannelEntity(channel), recipient: recipient, request: reply?.request,
                                     message: text)
            intent.context = context
            _ = try await intent.perform()

            #expect(host.confirmations == [.init(channel: "Studio demo", message: text, recipient: recipient)])
            #expect(RequestRecorder.requests.filter { $0.hasPrefix("POST ") } == ["POST /api/v1/channels/studio-demo/messages"])
            var snapshot = api.observe(channelId: "studio-demo").makeAsyncIterator()
            let state = try #require(try await snapshot.next()?.state)
            let posted = state.messages.filter { $0.text.hasSuffix(text) }
            #expect(posted.map(\.text) == [recipient.map { "@\(agentHandleFromName($0)) \(text)" } ?? text])
            #expect(posted.first?.sender == .user)
            if reply != nil {
                #expect(context.withReplies(card).isReplied)
                #expect(state.channel.requestSequence == nil)
            }
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
            #expect(host.holds["studio-demo"] == 0, "The intent released the channel it held")
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
            #expect(host.confirmations.count == 1 && host.held.isEmpty)
            #expect(!RequestRecorder.requests.contains { $0.hasPrefix("POST ") })
        }

        /// Run alone against a fresh private demo, before any other fixture replies.
        @Test(.enabled(if: demoURL != nil))
        func spotlightReplyConfirmsAndAnswersTheOriginalRequestWithoutOpeningOrMarkingRead() async throws {
            let host = try TestHost.demo()
            let api = try #require(host.api)
            let context = host.context
            _ = try await context.catchUp(channelID: "studio-demo")
            let before = try #require(host.store("studio-demo")?.state)
            let request = try #require(before.request)
            let agent = try #require(([before.lead] + before.members).first { $0.id == request.sender.agentId })
            let item = MenuBarStatus.Item(id: before.channel.id, name: before.channel.name, subtitle: "",
                                         agent: agent, sequence: request.sequence,
                                         quote: NotificationText.plainText(request.text))
            let entry = try #require(WaitingRequestEntry(item: item, serverURL: api.baseURL.absoluteString))
            let text = "Spotlight reply fixture \(UUID().uuidString.prefix(8))"
            var intent = ReplyToRequestIntent(request: WaitingRequestEntity(entry), message: "  \(text)\n")
            intent.context = context
            RequestRecorder.reset()
            _ = try await intent.perform()
            let writes = RequestRecorder.requests.filter { !$0.hasPrefix("GET ") }
            #expect(writes == ["POST /api/v1/channels/studio-demo/messages"])
            #expect(host.confirmations == [.init(channel: before.channel.name, message: text, recipient: agent.name)])
            var stream = api.observe(channelId: before.channel.id).makeAsyncIterator()
            let after = try #require(try await stream.next()?.state)
            #expect(after.channel.requestSequence == nil)
            #expect(after.channel.seenThrough == before.channel.seenThrough)
            #expect(after.messages.filter { $0.id == intent.sendID }.map(\.text) == ["@\(agentHandleFromName(agent.name)) \(text)"])
            #expect(host.opened.isEmpty && host.store("studio-demo")?.sendAttempts.isEmpty == true)
            print("Spotlight request reply: confirmed \(agent.name) in \(before.channel.name), one POST, no read write, UUID \(intent.sendID)")
        }
    }
}

// MARK: Fixtures

/// Records what the app asks Spotlight to do, and fails on request.
@MainActor
private final class FakeSpotlightIndex {
    private(set) var operations: [String] = []
    private(set) var added: [ChannelEntity] = []
    var fails = false

    var index: ChannelSpotlight.Index {
        .init(add: { entities in try await self.record("add " + entities.map(\.id).joined(separator: " "), entities) },
              remove: { ids in try await self.record("remove " + ids.joined(separator: " ")) },
              removeAll: { try await self.record("remove all") })
    }

    private func record(_ operation: String, _ entities: [ChannelEntity] = []) throws {
        if fails { throw CancellationError() }
        operations.append(operation)
        added += entities
    }
}

@MainActor
private final class TestHost {
    let api: ChannelAPI?
    let journal = ChannelSendJournal(directory: FileManager.default.temporaryDirectory
        .appending(path: "IntentsTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    private var stores: [String: ChannelStore] = [:]
    private(set) var holds: [String: Int] = [:]
    private(set) var held: [String] = []
    private(set) var opened: [String] = []
    private(set) var confirmations: [ChannelIntentsContext.SendConfirmation] = []
    var declines = false
    var waitingRequests: [WaitingRequestEntry] = []
    private(set) var revealedRequests: [String] = []
    /// Installs a context backed by this host, which intents use until the next is installed.
    var context: ChannelIntentsContext {
        let context = ChannelIntentsContext(host: .init(
            api: { self.api },
            store: { self.store($0) },
            hold: { store in
                self.held.append(store.id)
                self.holds[store.id, default: 0] += 1
                if self.holds[store.id] == 1 { store.connect() }
            },
            release: { store in
                self.holds[store.id, default: 1] -= 1
                if self.holds[store.id] == 0 { store.disconnect() }
            },
            open: { self.opened.append($0) },
            requests: { self.waitingRequests },
            revealRequest: { self.revealedRequests.append("\($0):\($1)") }
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

private func channel(_ id: String, _ name: String, purpose: String? = nil, latest: Int = 0, seen: Int = 0,
                     completed: Int? = nil, request: Int? = nil,
                     updatedAt: String = "2026-01-15T00:00:00.000Z") -> Channel {
    Channel(id: id, name: name, purpose: purpose, model: .init(provider: "test", name: "test"), latestSequence: latest,
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
