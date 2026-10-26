import Foundation

/// The catch-up prompt: shown lines, the waiting request, and the instructions that frame them.
struct CatchUpPrompt: Sendable, Hashable {
    static let maximumResponseTokens = 360

    static let instructions = """
    You catch a reader up on a team chat they stepped away from. Messages call the reader "you" or \
    "the user". Everyone else is a lead agent or a member agent.
    Each message reads "[number] Speaker: text", or "[number] Speaker to Name: text" when it was \
    addressed to Name. The speaker is who acted, unless the text says someone else did.
    Pick at most three meaningful changes, most important first: decisions, finished work, shared \
    files, problems and open questions. Leave out what the reader did or decided.
    For each change, list the numbers of the messages it comes from, then write one sentence of \
    at most 16 words, in the third person and your own words, naming who did what. Use the past \
    tense for what was done. When a message only plans or proposes something, say who plans or \
    proposed it, never that it was done. Never mention message numbers.
    State only facts written in those messages. Never guess outcomes, names, numbers or reasons.
    Skip greetings, thanks, acknowledgements, repeated status lines and filler.
    If nothing meaningful happened, return an empty list of changes.
    """

    let entries: [CatchUpEntry]
    let request: CatchUpEntry?

    var text: String {
        var text = "Unread messages, oldest first. Each line starts with its message number.\n\n"
        text += entries.isEmpty ? "(none)" : entries.map(\.line).joined(separator: "\n")
        if let request {
            text += "\n\nWaiting for your reply:\n" + request.line
        }
        return text
    }

    /// Drops the lowest-priority, then oldest, lines until `measure` reports the prompt fits in
    /// `budget` tokens. The waiting request always stays. Nil when even the request alone is too big
    /// or nothing is left to summarize.
    static func fitted(_ request: CatchUpRequest, budget: Int,
                       measure: (String) async -> Int) async -> CatchUpPrompt? {
        var kept = request.entries
        let removalOrder = request.entries.sorted { ($0.priority, $0.sequence) < ($1.priority, $1.sequence) }
        var removed = 0

        for _ in 0..<12 {
            let prompt = CatchUpPrompt(entries: kept, request: request.request)
            let tokens = await measure(prompt.text)
            if tokens <= budget {
                return kept.isEmpty && request.request == nil ? nil : prompt
            }
            guard removed < removalOrder.count else { return nil }
            let overshoot = 1 - Double(budget) / Double(max(tokens, 1))
            let count = min(removalOrder.count - removed, max(1, Int((Double(kept.count) * overshoot).rounded(.up))))
            let dropping = Set(removalOrder[removed..<(removed + count)].map(\.sequence))
            kept.removeAll { dropping.contains($0.sequence) }
            removed += count
        }
        return nil
    }

    /// A prompt with half the lines, keeping the highest-priority and newest.
    func halved() -> CatchUpPrompt? {
        guard entries.count > 1 else { return nil }
        let keep = Set(entries.sorted { ($0.priority, $0.sequence) > ($1.priority, $1.sequence) }
            .prefix(entries.count / 2).map(\.sequence))
        return CatchUpPrompt(entries: entries.filter { keep.contains($0.sequence) }, request: request)
    }

    /// A rough count for when the model can't measure: about three characters per token.
    static func estimatedTokens(_ text: String) -> Int {
        text.utf8.count / 3 + 1
    }
}

/// What the model returned, before grounding.
struct CatchUpDraft: Sendable, Hashable {
    struct Change: Sendable, Hashable {
        var summary: String
        var sources: [Int]
    }

    var needsYou: String?
    var changes: [Change]
}

/// A draft's lines, after grounding, and the lines that didn't make it.
struct CatchUpAssembly: Sendable {
    let result: CatchUpResult
    let rejected: [CatchUpRejection]
}

/// A model-written line the card won't show, and why.
struct CatchUpRejection: Sendable, Equatable {
    enum Reason: String, Sendable {
        /// Its words, names, numbers or citations aren't backed by the messages it cites.
        case ungrounded
        /// It opens with someone its messages don't show acting, such as an addressee or "you".
        case misattributed
        /// It's in the first person or keeps a transcript header like "Lead to you:", copied from a
        /// message rather than summarizing it.
        case copied
        /// It cites a message an earlier, kept line already covers.
        case overlapping
        /// It says what an earlier, kept line already says.
        case repeats
        /// It's a needs-you line with nothing from the request in it, like "Lead asked to confirm
        /// the pending decision".
        case vague
    }

    let text: String
    let reason: Reason
}

extension CatchUpDraft {
    /// Keeps only grounded, non-overlapping changes, ordered by the priority of what they cite.
    func assembled(prompt: CatchUpPrompt, request: CatchUpRequest) -> CatchUpAssembly {
        var evidence: [Int: String] = [:]
        var priority: [Int: Int] = [:]
        var actors: [Int: Set<String>] = [:]
        var statements: [Int: Grounding.Statement] = [:]
        for entry in prompt.entries {
            evidence[entry.sequence] = entry.evidence
            priority[entry.sequence] = entry.priority
            actors[entry.sequence] = entry.actors(among: request.participants)
            statements[entry.sequence] = entry.statement
        }
        let grounding = Grounding(evidence: evidence, participants: request.participants, actors: actors,
                                  statements: statements)
        let allowed = Set(prompt.entries.map(\.sequence))

        var rejected: [CatchUpRejection] = []
        var cited = Set<Int>()
        var gists: [Set<String>] = []
        var lines: [(line: CatchUp.Line, rank: Int, index: Int)] = []
        for (index, change) in changes.enumerated() {
            let line: CatchUp.Line
            switch grounding.verdict(change.summary, citing: change.sources, allowed: allowed) {
            case .kept(let kept): line = kept
            case .dropped(let reason):
                rejected.append(CatchUpRejection(text: change.summary, reason: reason))
                continue
            }
            guard cited.isDisjoint(with: line.sources) else {
                rejected.append(CatchUpRejection(text: line.text, reason: .overlapping))
                continue
            }
            let gist = Grounding.gist(line.text, participants: request.participants)
            guard !gists.contains(where: { Grounding.repeats(gist, $0) }) else {
                rejected.append(CatchUpRejection(text: line.text, reason: .repeats))
                continue
            }
            gists.append(gist)
            cited.formUnion(line.sources)
            lines.append((line, line.sources.compactMap { priority[$0] }.max() ?? 0, index))
        }
        let ordered = lines.sorted { ($0.rank, -$0.index) > ($1.rank, -$1.index) }.prefix(3).map(\.line)

        var needs: CatchUp.Line?
        if let waiting = prompt.request {
            let requester = Set([waiting.speaker?.lowercased()].compactMap { $0 })
            let requestGrounding = Grounding(evidence: [waiting.sequence: waiting.evidence],
                                             participants: request.participants,
                                             extraWords: Grounding.requestWords,
                                             actors: [waiting.sequence: requester], requiresActor: true,
                                             statements: [waiting.sequence: waiting.statement],
                                             requiresSpecifics: true)
            if let needsYou {
                switch requestGrounding.verdict(needsYou, citing: [waiting.sequence], allowed: [waiting.sequence]) {
                case .kept(let line): needs = line
                case .dropped(let reason): rejected.append(CatchUpRejection(text: needsYou, reason: reason))
                }
            }
            if needs == nil { needs = Self.fallbackNeedsYou(waiting) }
        }

        guard needs != nil || !ordered.isEmpty else { return CatchUpAssembly(result: .nothingNew, rejected: rejected) }
        let catchUp = CatchUp(needsYou: needs, changes: Array(ordered), through: request.through)
        return CatchUpAssembly(result: .ready(catchUp), rejected: rejected)
    }

    /// The request's own words, quoted, for when the model's paraphrase can't be trusted: its last
    /// question, since asks usually close a message, or else its last sentence addressed to you.
    /// Message numbers like "seq 530" are removed, since they mean nothing outside the prompt.
    static func fallbackNeedsYou(_ request: CatchUpEntry) -> CatchUp.Line {
        let sentences = request.text.split(separator: "\n")
            .flatMap { Grounding.sentences(String($0)) }
            .map(Grounding.cleaned)
            .filter { !$0.isEmpty }
        let speaker = request.speaker ?? "Someone"
        let text: String
        if let question = sentences.last(where: { $0.hasSuffix("?") }) {
            text = "\(speaker) asked: \u{201C}\(catchUpTruncated(question, limit: 120))\u{201D}"
        } else {
            let addressed = sentences.last { sentence in
                Grounding.tokens(sentence).contains { ["you", "your"].contains($0.lowercased()) }
            }
            let quote = addressed ?? sentences.last ?? request.text
            text = "\(speaker) is waiting: \u{201C}\(catchUpTruncated(quote, limit: 120))\u{201D}"
        }
        return CatchUp.Line(text: text, sources: [request.sequence])
    }
}
