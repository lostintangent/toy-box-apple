import ChannelKit
import Foundation
import Testing
@testable import ChannelIntelligence

/// Each case here is a mistake the real model made on a real channel transcript, restated with
/// fixture names: lines that read well and use the messages' own words, but credit the wrong person,
/// copy the speaker's "we", say one thing twice, or miss an ask that came at the end.
struct AttributionTests {
    typealias T = TestChannel

    static let ending = "I'll confirm it with a real drag once the test bundle is approved. "
        + "That approval from seq 530 is the one thing I still need from you."

    func request() throws -> CatchUpRequest {
        let state = try T.state([
            T.message(1, from: "user", "How is the release going?"),
            T.message(2, from: "ada-engineer", "@moss Read positions now only move forward, so an older tab can't lower them."),
            T.message(3, from: "moss-reviewer", "@lead All four review changes are in 4c1d9e0, pushed to main, and all 245 tests pass."),
            T.message(4, "Done. The repository is public. Iris also confirmed the app builds as a universal binary."),
            T.message(5, "I changed bun run validate to also build a test copy with its own bundle ID."),
            T.message(6, "@iris the user decided the app requires macOS 27 and Apple Silicon only. Please switch the package first."),
            T.message(7, from: "ada-engineer", "Moss, I changed only the spec's platform line. Its history paragraphs still need your pass."),
            T.message(8, from: "moss-reviewer", "Verified again on a clean checkout: all 245 tests pass on main."),
            T.message(9, """
                No, we never did. We checked behavior and visuals in the real window at every milestone, but \
                nobody measured frame time, CPU or memory. \(T.paragraph) \(T.paragraph) \(T.paragraph) \(Self.ending)
                """, request: true),
        ], requestSequence: 9)
        return try #require(CatchUpRequest(server: T.server, state: state, unreadAfter: 1,
                                           minimumUnread: 1, minimumCharacters: 0))
    }

    func assemble(needsYou: String? = nil, _ changes: [(String, [Int])]) throws -> CatchUpAssembly {
        let request = try request()
        let prompt = CatchUpPrompt(entries: request.entries, request: request.request)
        let draft = CatchUpDraft(needsYou: needsYou, changes: changes.map { .init(summary: $0.0, sources: $0.1) })
        return draft.assembled(prompt: prompt, request: request)
    }

    @Test func addresseesAreNotActors() throws {
        let assembly = try assemble([
            ("Lead pushed 4c1d9e0 to main.", [3]),
            ("Moss pushed 4c1d9e0 to main with all 245 tests passing.", [3]),
        ])
        #expect(assembly.result.catchUp?.changes.map(\.text) == ["Moss pushed 4c1d9e0 to main with all 245 tests passing."])
        #expect(assembly.rejected == [CatchUpRejection(text: "Lead pushed 4c1d9e0 to main.", reason: .misattributed)])
    }

    @Test func someoneTheSpeakerReportsOnCanAct() throws {
        let assembly = try assemble([("Iris confirmed the app builds as a universal binary.", [4])])
        #expect(assembly.result.catchUp?.changes.map(\.text) == ["Iris confirmed the app builds as a universal binary."])
    }

    @Test func theOpenerMustActWhereTheLineComesFrom() throws {
        let assembly = try assemble([
            ("Lead confirmed all 245 tests pass on main.", [3, 4]),
            ("Moss confirmed all 245 tests pass on main.", [4, 3]),
        ])
        #expect(assembly.result.catchUp?.changes == [.init(text: "Moss confirmed all 245 tests pass on main.", sources: [3, 4])])
        #expect(assembly.rejected == [CatchUpRejection(text: "Lead confirmed all 245 tests pass on main.", reason: .misattributed)])
    }

    @Test func someoneSpokenToIsNotAnActor() throws {
        let assembly = try assemble([
            ("Moss changed the spec's platform line.", [7]),
            ("Ada changed the spec's platform line.", [7]),
        ])
        #expect(assembly.result.catchUp?.changes.map(\.text) == ["Ada changed the spec's platform line."])
        #expect(assembly.rejected.map(\.reason) == [.misattributed])
        let named = "Kit, Moss and Iris shipped it. Moss, please check the build."
        #expect(CatchUpEntry.withoutVocatives(named, participants: ["kit", "moss", "iris"])
                == "Kit, Moss and Iris shipped it. please check the build.")
    }

    @Test func aReportedFixIsNotTheReporters() throws {
        // Real case: Shell's message said Core fixed the launch race, and the line credited Shell.
        let state = try T.state([
            T.message(1, from: "user", "How is the footer?"),
            T.message(2, from: "pixel-designer", """
                @moss The footer is now the sidebar's only progress indicator. While capturing I found a \
                launch race where the first load got cancelled and showed a false red "cancelled". \
                Ada fixed it earlier today. Moss, one question about the refresh shortcut.
                """),
            T.message(3, from: "kit-writer", "I've fixed the drafts flow, and the reconnect notes were fixed by Iris."),
        ])
        let request = try #require(CatchUpRequest(server: T.server, state: state, unreadAfter: 1,
                                                  minimumUnread: 1, minimumCharacters: 0))
        let prompt = CatchUpPrompt(entries: request.entries, request: nil)
        let draft = CatchUpDraft(needsYou: nil, changes: [
            .init(summary: "Pixel fixed the launch race that showed a false red 'cancelled'.", sources: [2]),
            .init(summary: "Ada fixed the launch race that showed a false red 'cancelled'.", sources: [2]),
            .init(summary: "Kit fixed the drafts flow.", sources: [3]),
        ])
        let assembly = draft.assembled(prompt: prompt, request: request)
        #expect(Set(assembly.result.catchUp?.changes.map(\.text) ?? []) == [
            "Ada fixed the launch race that showed a false red 'cancelled'.",
            "Kit fixed the drafts flow.",
        ])
        #expect(assembly.rejected == [CatchUpRejection(
            text: "Pixel fixed the launch race that showed a false red 'cancelled'.", reason: .misattributed)])
    }

    @Test func subjectsAreReadAroundTheVerb() {
        let participants: Set<String> = ["ada", "core", "kit", "studio lead"]
        func subjects(_ text: String, _ verb: String = "fixed") -> Set<String> {
            Grounding.subjects(of: verb, in: text, speaker: "Kit", participants: participants)
        }
        #expect(subjects("Core fixed it in msg 474.") == ["core"])
        #expect(subjects("Core and Ada have both fixed the race.") == ["core", "ada"])
        #expect(subjects("The race was fixed by Studio Lead.") == ["studio lead"])
        #expect(subjects("I've fixed one, and you fixed the other.") == ["kit", "you"])
        #expect(subjects("Designer, I changed only the spec's platform line.", "changes") == ["kit"])
        #expect(subjects("Thanks Core. The fix landed.") == [])
        #expect(subjects("Core asked for it. Fixed now.") == [])
    }

    @Test func aVagueNeedsYouQuotesTheRequest() throws {
        let vague = try assemble(needsYou: "The Lead asked to confirm the pending decision.", [])
        #expect(vague.result.catchUp?.needsYou?.text
                == "Lead is waiting: \u{201C}That approval is the one thing I still need from you.\u{201D}")
        #expect(vague.rejected.map(\.reason) == [.vague])

        let specific = try assemble(needsYou: "Lead asked you to approve the test bundle for a real drag.", [])
        #expect(specific.result.catchUp?.needsYou?.text == "Lead asked you to approve the test bundle for a real drag.")
    }

    @Test func paraphrasedVerbsAreFine() {
        let grounding = Grounding(evidence: [1: "Ada Read positions now only move forward."],
                                  participants: ["ada", "moss"], actors: [1: ["ada"]])
        #expect(grounding.line("Ada made read positions only move forward.", citing: [1], allowed: [1]) != nil)
    }

    @Test func theFirstSourceIsTheOpenersMessage() {
        let grounding = Grounding(evidence: [1: "Kit shared sidebar files and notes.", 2: "Pixel shared sidebar files."],
                                  participants: ["kit", "pixel"], actors: [1: ["kit"], 2: ["pixel"]])
        #expect(grounding.line("Pixel shared sidebar files.", citing: [1, 2], allowed: [1, 2])?.sources == [2, 1])
        #expect(grounding.line("Kit shared sidebar files.", citing: [1, 2], allowed: [1, 2])?.sources == [1, 2])
    }

    @Test func theReaderNeverOpensAChange() throws {
        let assembly = try assemble([
            ("You changed bun run validate to build a test copy.", [5]),
            ("The user decided the app requires macOS 27.", [6]),
            ("Lead changed bun run validate to build a test copy with its own bundle ID.", [5]),
        ])
        #expect(assembly.result.catchUp?.changes.map(\.text) == ["Lead changed bun run validate to build a test copy with its own bundle ID."])
        #expect(assembly.rejected.map(\.reason) == [.misattributed, .misattributed])
    }

    @Test func firstPersonMeansCopied() throws {
        let assembly = try assemble([("I changed bun run validate to build a test copy.", [5])])
        #expect(assembly.rejected == [CatchUpRejection(text: "I changed bun run validate to build a test copy.", reason: .copied)])
        #expect(Grounding.isFirstPerson("We checked the real window."))
        #expect(Grounding.isFirstPerson("Lead said our build is green."))
        #expect(!Grounding.isFirstPerson("Iris moved the US English strings."))
        #expect(!Grounding.isFirstPerson("Ada fixed the build."))
    }

    @Test func sayingItTwiceKeepsTheFirst() throws {
        let assembly = try assemble([
            ("Moss pushed 4c1d9e0 to main with all 245 tests passing.", [3]),
            ("Moss confirmed all 245 tests pass on main.", [8]),
            ("Ada made read positions only move forward.", [2]),
        ])
        #expect(assembly.result.catchUp?.changes.count == 2)
        #expect(assembly.rejected == [CatchUpRejection(text: "Moss confirmed all 245 tests pass on main.", reason: .repeats)])
        #expect(!Grounding.repeats(Grounding.gist("Pixel shared the file Spec.", participants: ["pixel"]),
                                   Grounding.gist("Kit shared the file Plan.", participants: ["kit"])))
    }

    @Test func theRequestKeepsItsEnding() throws {
        let request = try #require(try request().request)
        #expect(request.text.count <= CatchUpEntry.maximumRequestCharacters)
        #expect(request.text.hasPrefix("No, we never did."))
        #expect(request.text.hasSuffix(Self.ending))
    }

    @Test func needsYouOpensWithTheRequester() throws {
        let kept = try assemble(needsYou: "Lead needs you to approve the test bundle.", [])
        #expect(kept.result.catchUp?.needsYou?.text == "Lead needs you to approve the test bundle.")

        let fallback = "Lead is waiting: \u{201C}That approval is the one thing I still need from you.\u{201D}"
        let copied = try assemble(needsYou: "We checked behavior and visuals in the real window at every milestone.", [])
        #expect(copied.result.catchUp?.needsYou == .init(text: fallback, sources: [9]))
        #expect(copied.rejected.map(\.reason) == [.copied])

        let someoneElse = try assemble(needsYou: "Iris needs you to approve the test bundle.", [])
        #expect(someoneElse.result.catchUp?.needsYou?.text == fallback)
        #expect(someoneElse.rejected.map(\.reason) == [.misattributed])

        let unnamed = try assemble(needsYou: "Approve the test bundle.", [])
        #expect(unnamed.result.catchUp?.needsYou?.text == fallback)

        let echoed = try assemble(needsYou: "Lead to you: That approval is the one thing I still need.", [])
        #expect(echoed.result.catchUp?.needsYou?.text == fallback)
        #expect(echoed.rejected.map(\.reason) == [.copied])
    }

    @Test func transcriptHeadersAreCopies() {
        #expect(Grounding.echoesTranscript("Lead to you: Should the beta wait?"))
        #expect(Grounding.echoesTranscript("[12] Ada to Moss, you: The tests pass."))
        #expect(Grounding.echoesTranscript("Studio Lead: The preview moved."))
        #expect(!Grounding.echoesTranscript("Lead asked you to decide: ship or wait."))
        #expect(!Grounding.echoesTranscript("Lead needs you to approve the test bundle."))
    }

    @Test func fallbackPrefersTheLastQuestion() {
        let entry = CatchUpEntry(sequence: 30, speaker: "Lead", addressees: [], text: """
            Quick update. Could you approve the test bundle? The viewer is done.
            Could you turn on Reduce Transparency and reply here? Designer will capture both.
            """, priority: 6)
        #expect(CatchUpDraft.fallbackNeedsYou(entry).text
                == "Lead asked: \u{201C}Could you turn on Reduce Transparency and reply here?\u{201D}")
    }

    @Test func messageNumbersAreRemoved() {
        #expect(Grounding.cleaned("Designer signed off on the footer spinner in msg 480.") == "Designer signed off on the footer spinner.")
        #expect(Grounding.cleaned("Kit shared the plan (message 12).") == "Kit shared the plan.")
        #expect(Grounding.cleaned("Lead still needs the approval from seq 530.") == "Lead still needs the approval.")
        #expect(Grounding.cleaned("Ada merged PR #12 for version 2.0.") == "Ada merged PR #12 for version 2.0.")
    }

    @Test func openingNames() {
        let participants: Set<String> = ["pixel", "kit", "lead", "you"]
        #expect(Grounding.openingNames("Pixel and Kit shared files.", participants: participants) == ["pixel", "kit"])
        #expect(Grounding.openingNames("The user decided to ship.", participants: participants) == ["you"])
        #expect(Grounding.openingNames("The routine was scheduled.", participants: participants) == [])
        #expect(Grounding.openingNames("Lead asked Kit to review.", participants: participants) == ["lead"])
        #expect(Grounding.openingNames("Pixel, Kit, and Lead reviewed it.", participants: participants) == ["pixel", "kit", "lead"])
        #expect(Grounding.openingNames("The Lead changed the preview.", participants: participants) == ["lead"])
        #expect(Grounding.predicate("Pixel, Kit, and Lead also reviewed it.", participants: participants) == "reviewed")
        #expect(Grounding.predicate("The routine was scheduled.", participants: participants) == nil)
    }

    @Test func theVerbMustBeTheOpeners() throws {
        // Real output: Lead said the shim "can go", Shell removed it, and both messages back the line.
        // Then a mid-message @lead, rendered "Lead" for the model, made Lead an actor.
        let state = try T.state([
            T.message(1, from: "user", "How is the rail?"),
            T.message(2, "@shell The composer uses the plain rail now, so the alignsToMessages shim can go. I'll close t75."),
            T.message(3, from: "pixel-designer", "@lead I've removed the alignsToMessages shim, and t75's rail tests pass."),
            T.message(4, from: "kit-writer", "@moss Ready. The full suite passes with 244 tests. @lead t75 is ready to close."),
        ])
        let request = try #require(CatchUpRequest(server: T.server, state: state, unreadAfter: 1,
                                                  minimumUnread: 1, minimumCharacters: 0))
        let prompt = CatchUpPrompt(entries: request.entries, request: nil)
        let draft = CatchUpDraft(needsYou: nil, changes: [
            .init(summary: "Lead removed the alignsToMessages shim for t75.", sources: [2, 3]),
            .init(summary: "Lead confirmed the full suite passes with 244 tests.", sources: [4]),
            .init(summary: "Pixel removed the alignsToMessages shim for t75.", sources: [2, 3]),
        ])
        let assembly = draft.assembled(prompt: prompt, request: request)
        #expect(assembly.result.catchUp?.changes == [.init(text: "Pixel removed the alignsToMessages shim for t75.", sources: [3, 2])])
        #expect(assembly.rejected.map(\.reason) == [.misattributed, .misattributed])
    }
}
