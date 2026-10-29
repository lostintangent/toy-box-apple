import ChannelIntelligence
import ChannelKit
import Foundation
import Testing

@MainActor
@Suite("Shared catch-up session", .serialized)
struct CatchUpSessionTests {
    let server = URL(string: "https://summary-\(UUID().uuidString.lowercased()).invalid/prefix")!

    private func make(_ state: ChannelState = summarySessionState(), unreadAfter: Int? = 10,
                      view: TranscriptView = .all, boundaryIsLoaded: Bool = true,
                      availability: IntelligenceAvailability = .available, isOn: Bool = true,
                      timeout: Duration = .seconds(15)) -> TranscriptCatchUpSession? {
        TranscriptCatchUpSession.make(server: server, state: state, unreadAfter: unreadAfter, view: view,
                                     boundaryIsLoaded: boundaryIsLoaded, availability: availability,
                                     isOn: isOn, timeout: timeout)
    }

    @Test func eligibilityRequiresTheLoadedBoundaryModelSettingAndEnoughAgentText() throws {
        let session = try #require(make())
        #expect(session.phase == .loading)
        #expect(session.summary == nil)
        #expect(session.generation != nil)
        #expect(session.isGenerating && !session.isFading)
        #expect(session.title == "Summarizing 20 new messages")
        #expect(make(boundaryIsLoaded: false) == nil)
        #expect(make(isOn: false) == nil)
        #expect(make(view: .yours) == nil)
        #expect(make(unreadAfter: nil) == nil)
        #expect(make(unreadAfter: 28) == nil)
        for reason in [IntelligenceUnavailableReason.deviceNotEligible, .appleIntelligenceNotEnabled,
                       .modelNotReady, .unsupportedLanguage] {
            #expect(make(availability: .unavailable(reason)) == nil)
        }
        var short = summarySessionState()
        short.messages = short.messages.map {
            ChannelMessage(id: $0.id, sequence: $0.sequence, timestamp: $0.timestamp,
                           sender: .agent("lead"), content: .text("On it"))
        }
        #expect(make(short) == nil)
        var ownMessages = summarySessionState()
        ownMessages.messages = ownMessages.messages.map {
            ChannelMessage(id: $0.id, sequence: $0.sequence, timestamp: $0.timestamp,
                           sender: .user, content: $0.content)
        }
        #expect(make(ownMessages) == nil)
    }

    @Test func cachedResultsAreReadyOnTheFirstFrameAndDoNotGenerateAgain() async throws {
        let service = SessionSummaryService(results: [.ready(summarySessionResult())])
        let first = try #require(make())
        await first.run(using: service)
        let expected = TranscriptCatchUpSession.Summary(catchUp: summarySessionResult(), count: 20)
        #expect(first.phase == .ready(expected))
        #expect(first.title == "Summary of 20 new messages")
        let second = try #require(make())
        #expect(second.phase == first.phase)
        #expect(second.generation == nil)
        await second.run(using: service)
        #expect(await service.count == 1)
    }

    @Test func aCachedUpdateIsReadySynchronouslyWithoutAnotherGeneration() async throws {
        let service = SessionSummaryService(results: [
            .ready(summarySessionResult()), .ready(summarySessionResult(through: 36)),
        ])
        let session = try #require(make())
        await session.run(using: service)
        let newer = summarySessionState(through: 36)
        let anotherLanding = try #require(make(newer))
        await anotherLanding.run(using: service)
        let generation = session.generation

        session.update(from: newer, server: server)

        #expect(session.phase == anotherLanding.phase)
        #expect(session.request.through == 36)
        #expect(session.summary?.count == 26)
        #expect(!session.isGenerating)
        #expect(session.generation == generation)
        await session.run(using: service)
        #expect(await service.count == 2)
    }

    @Test func dismissalsAreScopedToServerChannelAndUnreadBoundary() async throws {
        let session = try #require(make())
        session.dismiss()
        #expect(session.generation == nil)
        #expect(make() == nil)
        #expect(make(unreadAfter: 9) != nil)
        #expect(make(summarySessionState(channel: "another")) != nil)
        let otherServer = URL(string: server.absoluteString + "/another")!
        #expect(TranscriptCatchUpSession.make(
            server: otherServer, state: summarySessionState(), unreadAfter: 10, view: .all,
            boundaryIsLoaded: true, availability: .available, isOn: true) != nil)
        await session.run(using: SessionSummaryService(results: [.ready(summarySessionResult())]))
        #expect(session.summary == nil)
    }

    @Test func aDismissedReadySummaryCannotStartAnotherUpdateBeforeItsFade() async throws {
        let session = try #require(make())
        await session.run(using: SessionSummaryService(results: [.ready(summarySessionResult())]))
        session.dismiss()
        session.update(from: summarySessionState(through: 36), server: server)
        #expect(session.generation == nil)
        #expect(session.request.through == 30)
        #expect(make() == nil)
    }

    @Test(arguments: [CatchUpResult.nothingNew, .declined, .unavailable(.modelNotReady)])
    func initialNonresultsFadeAndCollapseWithoutCaching(result: CatchUpResult) async throws {
        let session = try #require(make())
        await session.run(using: SessionSummaryService(results: [result]))
        #expect(session.phase == .collapsed)
        #expect(session.isFading)
        #expect(make()?.phase == .loading)
    }

    @Test func updateRequiresFourNewAgentMessagesAndPreservesItsOriginalScope() async throws {
        let session = try #require(make())
        await session.run(using: SessionSummaryService(results: [.ready(summarySessionResult())]))
        let first = session.phase
        let summary = try #require(session.summary)
        #expect(summary.newerMessageCount(in: summarySessionState(through: 33).messages) == nil)
        #expect(summary.newerMessageCount(in: summarySessionState(through: 34).messages) == 4)
        session.update(from: summarySessionState(through: 33), server: server)
        #expect(session.phase == first)
        #expect(session.request.through == 30)
        session.update(from: summarySessionState(through: 36, channel: "another"), server: server)
        session.update(from: summarySessionState(through: 36), server: URL(string: server.absoluteString + "/other")!)
        #expect(session.phase == first)
        #expect(session.request.through == 30)
        session.update(from: summarySessionState(through: 34), server: server)
        #expect(session.phase == .updating(try #require(session.summary)))
        #expect(session.request.through == 34)
    }

    @Test(arguments: [CatchUpResult.declined, .nothingNew, .unavailable(.modelNotReady)])
    func aFailedUpdateRestoresBothSummaryAndCoverageAndCanRetry(result: CatchUpResult) async throws {
        let service = SessionSummaryService(results: [
            .ready(summarySessionResult()), result, .ready(summarySessionResult(through: 36)),
        ])
        let session = try #require(make())
        await session.run(using: service)
        let first = try #require(session.summary)
        let oldGeneration = session.generation
        session.update(from: summarySessionState(through: 36), server: server)
        #expect(session.phase == .updating(first))
        #expect(session.title == "Summarizing 26 new messages")
        #expect(session.generation != oldGeneration)
        await session.run(using: service)
        #expect(session.phase == .ready(first))
        #expect(session.request.through == 30)
        #expect(session.title == "Summary of 20 new messages")
        session.update(from: summarySessionState(through: 36), server: server)
        await session.run(using: service)
        #expect(session.summary?.catchUp.through == 36)
        #expect(session.summary?.count == 26)
        #expect(await service.count == 3)
    }

    @Test func duplicateRunCallsNeverStartASecondGeneration() async throws {
        let service = HeldSessionSummaryService()
        let session = try #require(make())
        let first = Task { await session.run(using: service) }
        await service.waitForCalls(1)
        await session.run(using: service)
        #expect(await service.count == 1)
        await service.answer(0, with: .ready(summarySessionResult()))
        await first.value
        #expect(session.summary?.count == 20)
    }

    @Test func dismissingAnInFlightGenerationNeverPublishesOrCachesItsLateResult() async throws {
        let service = HeldSessionSummaryService()
        let session = try #require(make())
        let run = Task { await session.run(using: service) }
        await service.waitForCalls(1)
        session.dismiss()
        await run.value
        await service.answer(0, with: .ready(summarySessionResult()))
        #expect(session.summary == nil)
        #expect(session.generation == nil)
        let request = try #require(CatchUpRequest(server: server, state: summarySessionState(), unreadAfter: 10))
        #expect(TranscriptCatchUpSession(request: request).phase == .loading)
    }

    @Test func callerCancellationReturnsWithoutWaitingForACancellationInsensitiveService() async throws {
        let service = HeldSessionSummaryService()
        let session = try #require(make())
        let first = Task { await session.run(using: service) }
        await service.waitForCalls(1)
        first.cancel()
        await first.value
        #expect(session.phase == .loading)
        #expect(make()?.phase == .loading)
        let second = Task { await session.run(using: service) }
        await service.waitForCalls(2)
        await service.answer(0, with: .ready(summarySessionResult(through: 99)))
        #expect(session.phase == .loading)
        await service.answer(1, with: .ready(summarySessionResult()))
        await second.value
        #expect(session.summary?.count == 20)
        #expect(session.summary?.catchUp.through == 30)
    }

    @Test func timeoutDoesNotWaitForANoncooperativeModelOrCacheALateAnswer() async throws {
        let service = HeldSessionSummaryService()
        let session = try #require(make(timeout: .zero))
        await session.run(using: service)
        #expect(session.phase == .collapsed)
        #expect(session.isFading)
        #expect(make()?.phase == .loading)
        await service.answerAll(with: .ready(summarySessionResult()))
        #expect(session.summary == nil)
    }

    @Test func aTimedOutUpdateKeepsItsOldResultAndCoverageDespiteALateAnswer() async throws {
        let first = try #require(make())
        await first.run(using: SessionSummaryService(results: [.ready(summarySessionResult())]))
        let session = try #require(make(timeout: .zero))
        let previous = try #require(session.summary)
        session.update(from: summarySessionState(through: 36), server: server)
        let service = HeldSessionSummaryService()
        await session.run(using: service)
        #expect(session.phase == .ready(previous))
        #expect(session.request.through == 30)
        await service.answerAll(with: .ready(summarySessionResult(through: 36)))
        #expect(session.phase == .ready(previous))
        #expect(make(summarySessionState(through: 36))?.phase == .loading)
    }

    @Test func successfulCoverageAndCacheKeysKeepServerChannelBoundaryAndSequenceDistinct() async throws {
        let service = SessionSummaryService(results: [.ready(summarySessionResult())])
        let session = try #require(make())
        await session.run(using: service)
        #expect(make(summarySessionState(channel: "another"))?.phase == .loading)
        #expect(make(unreadAfter: 9)?.phase == .loading)
        #expect(make(summarySessionState(through: 31))?.phase == .loading)
        let otherServer = URL(string: server.absoluteString + "/another")!
        let other = TranscriptCatchUpSession.make(
            server: otherServer, state: summarySessionState(), unreadAfter: 10, view: .all,
            boundaryIsLoaded: true, availability: .available, isOn: true)
        #expect(other?.phase == .loading)
    }

    @Test func theSummaryMemoEvictsItsOldestEntryAfterThirtyTwoResults() async throws {
        let service = SessionSummaryService(results: [.ready(summarySessionResult())])
        for index in 0...32 {
            let session = try #require(make(summarySessionState(channel: "memo-\(index)")))
            await session.run(using: service)
        }
        #expect(make(summarySessionState(channel: "memo-0"))?.phase == .loading)
        #expect(make(summarySessionState(channel: "memo-32"))?.summary != nil)
    }

    @Test func slotsUseTheFirstGroundedSourceOrTheExplicitRequestState() {
        let agent = summarySessionState().messages[11]
        let event = ChannelMessage(id: "event", sequence: 40, timestamp: agent.timestamp, sender: .system,
                                   content: .system(.init(type: "tasks_completed")))
        let messages = [agent, event]
        #expect(TranscriptCatchUpSlot(line: .init(text: "Line", sources: [12, 40]),
                                     messages: messages, isReplied: nil) == .avatar("lead"))
        #expect(TranscriptCatchUpSlot(line: .init(text: "Line", sources: [40, 12]),
                                     messages: messages, isReplied: nil) == .event("tasks_completed"))
        #expect(TranscriptCatchUpSlot(line: .init(text: "Line", sources: [40]),
                                     messages: messages, isReplied: false) == .need(isReplied: false))
        #expect(TranscriptCatchUpSlot(line: .init(text: "Line", sources: [99]),
                                     messages: messages, isReplied: nil) == .unknown)
    }
}

private actor SessionSummaryService: ChannelIntelligenceService {
    nonisolated let availability: IntelligenceAvailability = .available
    private var results: [CatchUpResult]
    private(set) var count = 0

    init(results: [CatchUpResult]) { self.results = results }
    func catchUp(_ request: CatchUpRequest) async -> CatchUpResult {
        count += 1
        return results.count > 1 ? results.removeFirst() : results.first ?? .declined
    }
    func altText(_ request: AltTextRequest) async -> AltText? { nil }
}

private actor HeldSessionSummaryService: ChannelIntelligenceService {
    nonisolated let availability: IntelligenceAvailability = .available
    private var requests: [CheckedContinuation<CatchUpResult, Never>?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var automaticResult: CatchUpResult?
    var count: Int { requests.count }

    func catchUp(_ request: CatchUpRequest) async -> CatchUpResult {
        if let automaticResult { return automaticResult }
        return await withCheckedContinuation { continuation in
            requests.append(continuation)
            let ready = waiters.filter { $0.0 <= requests.count }
            waiters.removeAll { $0.0 <= requests.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func answer(_ index: Int, with result: CatchUpResult) {
        let continuation = requests[index]
        requests[index] = nil
        continuation?.resume(returning: result)
    }
    func answerAll(with result: CatchUpResult) {
        automaticResult = result
        for index in requests.indices { answer(index, with: result) }
    }
    func altText(_ request: AltTextRequest) async -> AltText? { nil }
}

private func summarySessionResult(through: Int = 30) -> CatchUp {
    CatchUp(needsYou: nil, changes: [.init(text: "Lead verified the reconnect fix.", sources: [12])], through: through)
}

private func summarySessionState(through latest: Int = 30, channel: String = "summary") -> ChannelState {
    let channel = Channel(id: channel, name: "Catch-up", model: .init(provider: "test", name: "test"),
                          latestSequence: latest, seenThrough: 10, updatedAt: "2026-10-22T12:00:00Z")
    return ChannelState(revision: 1, channel: channel, lead: ChannelAgent(id: "lead", name: "Lead"),
                        messages: (1...latest).map {
        ChannelMessage(id: "m\($0)", sequence: $0, timestamp: "2026-10-22T12:00:00Z", sender: .agent("lead"),
                       content: .text("Update \($0) moves the launch checklist forward, with the reconnect fix verified "
                                      + "and the badge holding at zero unread."))
    })
}
