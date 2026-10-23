import ChannelKit
import CryptoKit
import Foundation
import FoundationModels
import Testing
@testable import ChannelIntelligence

/// Runs the real on-device model and records what it produced. Opt in with `TBM_LIVE_MODEL=1`.
/// `TBM_LIVE_REPORT` appends a Markdown report to a file. `TBM_LIVE_FIXTURE_DIR` adds local cases from
/// a `cases.json` of `[{"file", "unreadAfter", "through"?}]`, and `TBM_LIVE_IMAGES` adds images,
/// separated by colons. Keep private transcripts and images out of the repository.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TBM_LIVE_MODEL"] == "1"), .serialized)
struct LiveModelEvalTests {
    typealias T = TestChannel
    static let environment = ProcessInfo.processInfo.environment

    struct Case: Sendable {
        let name: String
        let state: ChannelState
        let unreadAfter: Int
        var minimumUnread = CatchUpRequest.defaultMinimumUnread
        var minimumCharacters = CatchUpRequest.defaultMinimumCharacters
    }

    func service() -> LiveChannelIntelligence {
        let directory = URL.temporaryDirectory.appending(path: "ChannelIntelligenceEval-\(UUID().uuidString)")
        return LiveChannelIntelligence(altTexts: AltTextStore(directory: directory))
    }

    @Test func modelFacts() async throws {
        let model = SystemLanguageModel.default
        let generation = CatchUpGeneration(model: model)
        let instructions = try await model.tokenCount(for: Instructions(CatchUpPrompt.instructions))
        let plain = try await model.tokenCount(for: CatchUpSchema.schema(needsYou: false))
        let withRequest = try await model.tokenCount(for: CatchUpSchema.schema(needsYou: true))
        report("""
            ## Model
            - Availability: \(IntelligenceAvailability(model.availability, supportsLocale: model.supportsLocale()))
            - Variant: \(model.variant.displayName), context \(model.contextSize) tokens, vision \(model.capabilities.contains(.vision))
            - Instructions \(instructions) tokens, schema \(plain) tokens (\(withRequest) with needs-you)
            - Prompt budget \(await generation.budget(needsYou: false)) tokens (\(await generation.budget(needsYou: true)) with needs-you)

            """)
    }

    @Test func committedCatchUps() async throws {
        let studio = try T.fixture("studio-demo")
        var waiting = studio
        waiting.messages.removeAll { $0.sequence > 15 }
        waiting.channel.requestSequence = 15
        waiting.request = waiting.messages.last

        let eligible = CatchUpRequest(server: T.server, state: studio, unreadAfter: 8) != nil
        report("Studio demo after 8 at the real thresholds: \(eligible ? "eligible" : "not eligible, no card")\n")

        let cases = [
            Case(name: "studio-demo after 8, thresholds lowered", state: studio, unreadAfter: 8,
                 minimumUnread: 1, minimumCharacters: 0),
            Case(name: "studio-demo through 15 with the request pending, thresholds lowered", state: waiting,
                 unreadAfter: 8, minimumUnread: 1, minimumCharacters: 0),
            Case(name: "history-demo after 450", state: try T.fixture("history-demo"), unreadAfter: 450),
            Case(name: "launch-week after 2", state: try T.fixture("launch-week"), unreadAfter: 2),
        ]
        for item in cases { await evaluate(item, service: service()) }
    }

    @Test func localCatchUps() async throws {
        guard let directory = Self.environment["TBM_LIVE_FIXTURE_DIR"].map({ URL(filePath: $0) }) else { return }
        struct Entry: Decodable { let file: String; let unreadAfter: Int; let through: Int? }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: directory.appending(path: "cases.json")))
        var states: [String: ChannelState] = [:]
        for entry in entries {
            if states[entry.file] == nil {
                states[entry.file] = try JSONDecoder().decode(ChannelState.self, from: Data(contentsOf: directory.appending(path: entry.file)))
            }
            var state = try #require(states[entry.file])
            if let through = entry.through { state.messages.removeAll { $0.sequence > through } }
            Self.applyPendingRequest(&state)
            let name = "\(entry.file) after \(entry.unreadAfter) through \(state.messages.last?.sequence ?? 0)"
            await evaluate(Case(name: name, state: state, unreadAfter: entry.unreadAfter), service: service())
        }
    }

    @Test func cachedResultIsImmediate() async throws {
        let service = service()
        let request = try #require(CatchUpRequest(server: T.server, state: try T.fixture("launch-week"), unreadAfter: 2))
        let cold = ContinuousClock.now
        let first = await service.catchUp(request)
        let coldTime = ContinuousClock.now - cold
        let warm = ContinuousClock.now
        let second = await service.catchUp(request)
        let warmTime = ContinuousClock.now - warm
        #expect(first == second)
        report("## Caching\nlaunch-week cold \(Self.seconds(coldTime)), cached \(Self.milliseconds(warmTime))\n")
    }

    @Test func cancellationFreesTheModel() async throws {
        let service = service()
        let request = try #require(CatchUpRequest(server: T.server, state: try T.fixture("launch-week"), unreadAfter: 2))
        let task = Task { await service.catchUp(request) }
        try await Task.sleep(for: .milliseconds(700))
        let cancelled = ContinuousClock.now
        task.cancel()
        _ = await task.value
        let probe = await service.queue.run(key: "probe", priority: .catchUp) { () async -> String? in "free" }
        let freed = ContinuousClock.now - cancelled
        #expect(probe == "free")
        report("## Cancellation\nCancelled 0.7 s into a catch-up. The next job started \(Self.milliseconds(freed)) later.\n")
    }

    @Test func catchUpPreemptsADescription() async throws {
        let service = service()
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let image = root.appending(path: "docs/transcript-events.png")
        let digest = SHA256.hash(data: try Data(contentsOf: image)).map { String(format: "%02x", $0) }.joined()
        let started = ContinuousClock.now
        let description = Task {
            let text = await service.altText(AltTextRequest(server: T.server, digest: digest, fileURL: image, priority: .focused))
            return (text, ContinuousClock.now - started)
        }
        try await Task.sleep(for: .milliseconds(1_000))
        let request = try #require(CatchUpRequest(server: T.server, state: try T.fixture("launch-week"), unreadAfter: 2))
        let asked = ContinuousClock.now
        let result = await service.catchUp(request)
        let catchUpTime = ContinuousClock.now - asked
        let (text, descriptionTime) = await description.value
        #expect(result.catchUp != nil)
        #expect(text != nil)
        report("## Preemption\nA catch-up asked for 1 s into an image description was ready in \(Self.seconds(catchUpTime)). "
               + "The description started over and arrived \(Self.seconds(descriptionTime)) after it was first asked for.\n")
    }

    @Test func oversizedTranscriptFits() async throws {
        let subjects = ["sidebar", "composer", "reconnect", "receipts", "viewer", "toolbar", "inspector", "search",
                        "settings", "menu bar", "dock badge", "notifications", "drafts", "reactions", "avatars", "tasks"]
        let verbs = ["rebuilt", "measured", "reviewed", "simplified", "documented"]
        let agents = ["ada-engineer", "moss-reviewer", "pixel-designer", "kit-writer", "iris-systems"]
        var messages: [ChannelMessage] = []
        for index in 0..<80 {
            let subject = subjects[index % subjects.count], verb = verbs[(index / subjects.count) % verbs.count]
            messages.append(T.message(index + 2, from: agents[index % agents.count], """
                I \(verb) the \(subject) flow end to end. \(T.paragraph) The \(subject) notes are in the \
                \(verb) section of the handoff, along with what still needs a decision from the lead.
                """))
        }
        let state = try T.state(messages)
        await evaluate(Case(name: "80 long messages (overflow)", state: state, unreadAfter: 1), service: service())
    }

    @Test func altText() async throws {
        let service = service()
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var images = ["docs/overview-inspector.png", "docs/transcript-events.png"].map { root.appending(path: $0) }
        images += (Self.environment["TBM_LIVE_IMAGES"] ?? "").split(separator: ":").map { URL(filePath: String($0)) }
        let pixel = URL.temporaryDirectory.appending(path: "eval-1x1.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            .write(to: pixel)
        images.insert(pixel, at: 0)

        var lines = ["## Image descriptions", "", "| Image | Kind | Model wrote | Shipped | Time |", "| --- | --- | --- | --- | --- |"]
        for url in images where FileManager.default.fileExists(atPath: url.path) {
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            let request = AltTextRequest(server: T.server, digest: digest, fileURL: url, priority: .focused)
            let outcome = try #require(await service.altTextOutcome(request))
            let cached = ContinuousClock.now
            let again = await service.altText(request)
            #expect(again == outcome.text)
            let raw = outcome.rawDescription ?? outcome.error ?? ""
            let recognized = " (OCR \(Self.seconds(outcome.recognition)), \(outcome.recognizedText.count) chars)"
            lines.append("| \(url.lastPathComponent) | \(outcome.kind ?? "") | \(raw) | \(outcome.text?.text ?? "nothing") | "
                         + "\(Self.seconds(outcome.duration)), cached \(Self.milliseconds(ContinuousClock.now - cached))\(recognized) |")
        }
        report(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Helpers

    func evaluate(_ item: Case, service: LiveChannelIntelligence) async {
        guard let request = CatchUpRequest(server: T.server, state: item.state, unreadAfter: item.unreadAfter,
                                           minimumUnread: item.minimumUnread, minimumCharacters: item.minimumCharacters) else {
            report("### \(item.name)\nNot eligible, no card.\n")
            return
        }
        let outcome = await service.catchUpOutcome(request)
        let trace = outcome.trace
        var lines = ["### \(item.name)",
                     "\(request.unreadFromOthers) unread from others, \(trace.candidateLines) candidate lines, "
                     + "\(trace.shownLines) shown, prompt \(trace.promptTokens.map(String.init) ?? "?") of "
                     + "\(trace.budget) tokens, \(trace.attempts) attempt(s), \(Self.seconds(trace.duration))"]
        if let draft = trace.draft {
            lines.append("Model draft:")
            if let needsYou = draft.needsYou { lines.append("- needs you: \(needsYou)") }
            lines += draft.changes.map { "- \($0.summary) \($0.sources)" }
            if draft.changes.isEmpty { lines.append("- (no changes)") }
        }
        for rejection in trace.rejected {
            lines.append("Dropped (\(rejection.reason.rawValue)): \u{201C}\(rejection.text)\u{201D}")
        }
        if let error = trace.error { lines.append("Error: \(error)") }
        switch outcome.result {
        case .ready(let catchUp):
            lines.append("Card:")
            if let needsYou = catchUp.needsYou { lines.append("- ❓ \(needsYou.text) \(needsYou.sources)") }
            lines += catchUp.changes.map { "- \($0.text) \($0.sources)" }
        case let other:
            lines.append("Result: \(other)")
        }
        report(lines.joined(separator: "\n") + "\n")
    }

    static func applyPendingRequest(_ state: inout ChannelState) {
        var pending: ChannelMessage?
        for message in state.messages {
            if message.sender.type == "user" { pending = nil }
            if message.sender.type == "agent", message.request == true { pending = message }
        }
        state.request = pending
        state.channel.requestSequence = pending?.sequence
    }

    static func seconds(_ duration: Duration) -> String {
        String(format: "%.2f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f ms", (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000)
    }

    func report(_ text: String) {
        print(text)
        guard let path = Self.environment["TBM_LIVE_REPORT"] else { return }
        let url = URL(filePath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((text + "\n").utf8).write(to: url)
        }
    }
}
