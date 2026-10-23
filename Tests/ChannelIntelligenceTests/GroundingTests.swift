import ChannelKit
import Foundation
import Testing
@testable import ChannelIntelligence

struct GroundingTests {
    let participants: Set<String> = ["lead", "ada", "moss", "pixel", "kit", "you"]
    let handoff = "Ada to Moss Messages and reconnects now use the same public Channel state. Moss Please review the handoff."

    func grounding(_ evidence: [Int: String]) -> Grounding {
        Grounding(evidence: evidence, participants: participants)
    }

    @Test func fabricatedOutcomeIsDropped() {
        let grounding = grounding([12: handoff])
        #expect(grounding.line("Moss approved the release and shipped version 2.0", citing: [12], allowed: [12]) == nil)
        #expect(grounding.line("Moss approved the release and shipped it.", citing: [12], allowed: [12]) == nil)
        #expect(grounding.line("Ada fixed the reconnect crash.", citing: [12], allowed: [12]) == nil)
    }

    @Test func faithfulParaphraseSurvives() throws {
        let grounding = grounding([12: handoff])
        let line = try #require(grounding.line(
            "Ada moved messages and reconnects onto the shared Channel state and asked Moss for review.",
            citing: [12], allowed: [12]))
        #expect(line.sources == [12])
        #expect(grounding.line("Ada asked Moss to review the handoff.", citing: [12], allowed: [12]) != nil)
    }

    @Test func citationsMustBeShownMessages() {
        let grounding = grounding([12: handoff, 13: "Kit shared the file Launch plan."])
        #expect(grounding.line("Ada asked Moss to review the handoff.", citing: [99], allowed: [12, 13]) == nil)
        #expect(grounding.line("Ada asked Moss to review the handoff.", citing: [], allowed: [12, 13]) == nil)
        #expect(grounding.line("Ada asked Moss to review the handoff.", citing: [12], allowed: [13]) == nil)
        #expect(grounding.line("Ada asked Moss to review the handoff.", citing: [13, 12, 12], allowed: [12, 13])?.sources == [12])
    }

    @Test func sourcesAreRankedByWhatTheyBack() throws {
        let grounding = grounding([
            4: "Reconnects now back off exponentially and cap at 30 seconds between attempts.",
            7: "Read positions now only move forward, so an older tab can't lower them.",
            9: "Pixel shared the file Sidebar redesign.",
            10: "Kit shared the file Sidebar notes.",
        ])
        // Live model output: "tabs" and "movement" must meet "tab" and "move", and the reconnect
        // message backs none of it, so the line points at 7 alone.
        let line = try #require(grounding.line("Ada fixed read position movement in older tabs.",
                                               citing: [4, 7], allowed: [4, 7, 9, 10]))
        #expect(line.sources == [7])
        // Equal backing keeps the older message first, whatever order the model cited them in.
        #expect(grounding.line("Pixel and Kit shared sidebar files.", citing: [10, 9], allowed: [9, 10])?.sources == [9, 10])
        #expect(grounding.line("Kit shared sidebar notes.", citing: [9, 10], allowed: [9, 10])?.sources == [10, 9])
    }

    @Test func onlyTheFirstSentenceIsKept() {
        let grounding = grounding([12: handoff])
        #expect(grounding.line("Ada asked Moss to review the handoff. Reply with your preference and any constraints.",
                               citing: [12], allowed: [12])?.text == "Ada asked Moss to review the handoff.")
    }

    @Test func stemsMeetAcrossCommonSuffixes() {
        #expect(Grounding.stem("tabs") == Grounding.stem("tab"))
        #expect(Grounding.stem("movement") == Grounding.stem("moved"))
        #expect(Grounding.stem("releases") == Grounding.stem("release"))
        #expect(Grounding.stem("processes") == Grounding.stem("process"))
        #expect(Grounding.stem("files") == Grounding.stem("file"))
        #expect(Grounding.stem("replies") == "reply")
        #expect(Grounding.stem("approved") != Grounding.stem("approach"))
    }

    @Test func numbersQuotesAndNamesMustAppearInSources() {
        let grounding = grounding([4: "Kit raised the attachment limit to 2 MB and shared \u{201C}Launch plan\u{201D}."])
        #expect(grounding.line("Kit raised the attachment limit to 4 MB.", citing: [4], allowed: [4]) == nil)
        #expect(grounding.line("Kit raised the attachment limit to 2 MB.", citing: [4], allowed: [4]) != nil)
        #expect(grounding.line("Kit shared \u{201C}Launch checklist\u{201D}.", citing: [4], allowed: [4]) == nil)
        #expect(grounding.line("Kit shared \u{201C}Launch plan\u{201D}.", citing: [4], allowed: [4]) != nil)
        #expect(grounding.line("Kit asked Tim to raise the attachment limit.", citing: [4], allowed: [4]) == nil)
        #expect(grounding.line("Kit raised the attachment limit, then Tim shared the plan.", citing: [4], allowed: [4]) == nil)
        #expect(grounding.line("Kit raised the attachment limit. Tim shared the plan.", citing: [4], allowed: [4])?.text
                == "Kit raised the attachment limit.")
    }

    @Test func modelFormattingIsCleaned() {
        #expect(Grounding.cleaned("- Ada asked Moss to review. [12, 13]") == "Ada asked Moss to review.")
        #expect(Grounding.cleaned("• Ada asked Moss to review (#12)") == "Ada asked Moss to review")
        #expect(Grounding.cleaned("Ada  asked\nMoss") == "Ada asked Moss")
    }

    @Test func overlongLinesAreDropped() {
        let grounding = grounding([12: handoff])
        let long = Array(repeating: "Ada asked Moss to review the handoff", count: 6).joined(separator: " and ")
        #expect(grounding.line(long, citing: [12], allowed: [12]) == nil)
    }
}

struct CatchUpAssemblyTests {
    typealias T = TestChannel

    func studio(requestSequence: Int? = nil) throws -> CatchUpRequest {
        var state = try T.fixture("studio-demo")
        if let requestSequence {
            state.messages.removeAll { $0.sequence > requestSequence }
            state.channel.requestSequence = requestSequence
        }
        return try #require(CatchUpRequest(server: T.server, state: state, unreadAfter: 8,
                                           minimumUnread: 1, minimumCharacters: 0))
    }

    @Test func groundedChangesSurviveInPriorityOrder() throws {
        let request = try studio()
        let prompt = CatchUpPrompt(entries: request.entries, request: request.request)
        let draft = CatchUpDraft(needsYou: nil, changes: [
            .init(summary: "Lead changed the preview.", sources: [14]),
            .init(summary: "Moss approved the release and shipped version 2.0", sources: [12]),
            .init(summary: "Ada moved messages and reconnects onto the same public Channel state.", sources: [12]),
            .init(summary: "Ada asked Moss to review the handoff.", sources: [12]),
        ])
        let assembly = draft.assembled(prompt: prompt, request: request)
        let catchUp = try #require(assembly.result.catchUp)
        #expect(catchUp.changes.map(\.text) == [
            "Ada moved messages and reconnects onto the same public Channel state.",
            "Lead changed the preview.",
        ])
        #expect(catchUp.needsYou == nil)
        #expect(catchUp.through == 17)
        #expect(assembly.rejected == [
            CatchUpRejection(text: "Moss approved the release and shipped version 2.0", reason: .misattributed),
            CatchUpRejection(text: "Ada asked Moss to review the handoff.", reason: .overlapping),
        ])
    }

    @Test func nothingGroundedMeansNothingNew() throws {
        let request = try studio()
        let prompt = CatchUpPrompt(entries: request.entries, request: nil)
        let draft = CatchUpDraft(needsYou: nil, changes: [.init(summary: "Moss shipped the release.", sources: [12])])
        #expect(draft.assembled(prompt: prompt, request: request).result == .nothingNew)
        #expect(CatchUpDraft(needsYou: nil, changes: []).assembled(prompt: prompt, request: request).result == .nothingNew)
    }

    @Test func needsYouIsGroundedInTheRequest() throws {
        let request = try studio(requestSequence: 15)
        let prompt = CatchUpPrompt(entries: request.entries, request: request.request)
        let draft = CatchUpDraft(needsYou: "Lead is waiting for you to choose where the shared library should sit.",
                                 changes: [.init(summary: "Lead asked where the shared library should sit.", sources: [15])])
        let catchUp = try #require(draft.assembled(prompt: prompt, request: request).result.catchUp)
        #expect(catchUp.needsYou == .init(text: "Lead is waiting for you to choose where the shared library should sit.", sources: [15]))
        #expect(catchUp.changes.isEmpty)
    }

    @Test func ungroundedNeedsYouFallsBackToTheQuestion() throws {
        let request = try studio(requestSequence: 15)
        let prompt = CatchUpPrompt(entries: request.entries, request: request.request)
        let draft = CatchUpDraft(needsYou: "Lead needs you to approve the 2.0 launch budget.", changes: [])
        let catchUp = try #require(draft.assembled(prompt: prompt, request: request).result.catchUp)
        #expect(catchUp.needsYou == .init(
            text: "Lead asked: \u{201C}Where should the shared library sit: near the entrance or beside the team desks?\u{201D}",
            sources: [15]))
    }
}

struct CatchUpBudgetTests {
    typealias T = TestChannel

    func request() throws -> CatchUpRequest {
        var state = try T.fixture("studio-demo")
        state.messages.removeAll { $0.sequence > 15 }
        state.channel.requestSequence = 15
        return try #require(CatchUpRequest(server: T.server, state: state, unreadAfter: 8,
                                           minimumUnread: 1, minimumCharacters: 0))
    }

    @Test func everythingFitsWhenThereIsRoom() async throws {
        let request = try request()
        let prompt = try #require(await CatchUpPrompt.fitted(request, budget: 10_000) { $0.count })
        #expect(prompt.entries == request.entries)
        #expect(prompt.text.hasSuffix("Waiting for your reply:\n" + (request.request?.line ?? "")))
    }

    @Test func lowestPriorityThenOldestLinesGoFirst() async throws {
        let request = try request()
        let full = CatchUpPrompt(entries: request.entries, request: request.request).text.count
        let prompt = try #require(await CatchUpPrompt.fitted(request, budget: full - 60) { $0.count })
        let lowest = request.entries.map(\.priority).min()
        let dropped = Set(request.entries.map(\.sequence)).subtracting(prompt.entries.map(\.sequence))
        #expect(!dropped.isEmpty)
        #expect(dropped.allSatisfy { sequence in request.entries.first { $0.sequence == sequence }?.priority == lowest })
        #expect(prompt.request == request.request)
        #expect(prompt.text.count <= full - 60)
    }

    @Test func requestAloneTooBigMeansNoPrompt() async throws {
        let request = try request()
        #expect(await CatchUpPrompt.fitted(request, budget: 10) { $0.count } == nil)
    }

    @Test func halvingKeepsTheMostImportantLines() throws {
        let request = try request()
        let prompt = CatchUpPrompt(entries: request.entries, request: request.request)
        let half = try #require(prompt.halved())
        #expect(half.entries.count == request.entries.count / 2)
        let kept = half.entries.map(\.priority).min() ?? 0
        let dropped = request.entries.filter { !half.entries.contains($0) }.map(\.priority).max() ?? 0
        #expect(kept >= dropped)
    }
}
