import Foundation
import NaturalLanguage

/// Decides whether a model-written line is backed by the messages it cites. Only a line's first
/// sentence is kept, and it survives only if:
/// - it cites at least one message the model was shown and is allowed to cite,
/// - it's written in the third person, not copied from a message in the first,
/// - the names it opens with are people its cited messages show acting, never an addressee or "you",
/// - every number, version or identifier in it appears in a cited message,
/// - every quoted phrase appears in a cited message,
/// - every capitalized name after its first word is a participant or appears in a cited message,
/// - at least 60% of its remaining content words match words in the cited messages, where only
///   neutral reporting verbs like "asked" or "shared" are exempt, never outcomes like "approved".
struct Grounding: Sendable {
    static let minimumSupport = 0.6
    static let maximumCharacters = 180

    enum Verdict: Equatable {
        case kept(CatchUp.Line)
        case dropped(CatchUpRejection.Reason)
    }

    /// Evidence text per message sequence.
    let evidence: [Int: String]
    /// Lowercased participant names.
    let participants: Set<String>
    /// Extra words that need no support, such as the vocabulary of asking for a reply.
    var extraWords: Set<String> = []
    /// Lowercased names a line citing each message may open with: its speaker, and anyone its text
    /// names. Addressees aren't actors. When empty, openings aren't checked.
    var actors: [Int: Set<String>] = [:]
    /// Whether a line must open with one of its sources' actors, as the needs-you line must.
    var requiresActor = false
    /// Who wrote each message and what it says, without the speaker and addressee prefix of its
    /// evidence, for reading who a message says did something. When empty, that isn't checked.
    var statements: [Int: Statement] = [:]
    /// Whether a line needs a word of its own from the messages, beyond who asked and generic
    /// words like "confirm" or "decision", as the needs-you line does.
    var requiresSpecifics = false

    struct Statement: Sendable {
        let speaker: String?
        let text: String
    }

    func line(_ text: String, citing sequences: [Int], allowed: Set<Int>) -> CatchUp.Line? {
        guard case .kept(let line) = verdict(text, citing: sequences, allowed: allowed) else { return nil }
        return line
    }

    func verdict(_ text: String, citing sequences: [Int], allowed: Set<Int>) -> Verdict {
        guard let text = Self.sentences(Self.cleaned(text)).first,
              text.count <= Self.maximumCharacters else { return .dropped(.ungrounded) }
        let cited = Set(sequences).intersection(allowed).filter { evidence[$0] != nil }
        guard !cited.isEmpty else { return .dropped(.ungrounded) }
        guard !Self.isFirstPerson(text), !Self.echoesTranscript(text) else { return .dropped(.copied) }
        guard let sources = attributedSources(for: text, ranked: scoredSources(for: text, cited: cited)) else {
            return .dropped(.misattributed)
        }
        let corpus = cited.sorted().compactMap { evidence[$0] }.joined(separator: "\n")
        guard Self.supports(text, corpus: corpus, participants: participants, extraWords: extraWords) else {
            return .dropped(.ungrounded)
        }
        guard !requiresSpecifics || isSpecific(text, corpus: corpus) else { return .dropped(.vague) }
        return .kept(CatchUp.Line(text: text, sources: sources))
    }

    /// "The Lead asked to confirm the pending decision" passes every other check because it says
    /// nothing to check. A specific line repeats at least one of the message's own content words.
    func isSpecific(_ text: String, corpus: String) -> Bool {
        let vocabulary = Vocabulary(corpus)
        return Self.contentWords(text, participants: participants).contains { word in
            !Self.reportingWords.contains(word) && !Self.statementWords.contains(word)
                && !Self.genericWords.contains(word) && !extraWords.contains(word) && vocabulary.contains(word)
        }
    }

    /// The line's sources with the first-named actor's strongest message first, so the avatar
    /// matches who the line is about, or nil when the line credits the wrong person. Each name a
    /// line opens with must have acted in a message that backs at least half as much of the line as
    /// its best source: "Lead pushed 2be64f7" can't cite Core's message to Lead, and "Lead
    /// confirmed universal builds" can't lean on Core's report by also citing an unrelated message
    /// from Lead. A summary of others' work never opens with "You" or "The user".
    func attributedSources(for text: String, ranked: [(sequence: Int, score: Int)]) -> [Int]? {
        let order = ranked.map(\.sequence)
        guard !actors.isEmpty else { return order }
        let names = Self.openingNames(text, participants: participants)
        guard let first = names.first else { return requiresActor ? nil : order }
        let best = ranked.first?.score ?? 0
        let substantial = ranked.filter { 2 * $0.score >= best }.map(\.sequence)
        func acting(_ name: String) -> [Int] {
            name == "you" ? [] : substantial.filter { actors[$0]?.contains(name) == true }
        }
        guard names.allSatisfy({ !acting($0).isEmpty }) else { return nil }
        var leading = acting(first)
        let verb = Self.predicate(text, participants: participants)
        if let verb, creditsSomeoneElse(verb, names: Set(names), in: substantial) { return nil }
        if let verb, !exemptPredicate(verb) {
            let witnessed = { (sequence: Int) in Vocabulary(evidence[sequence] ?? "").contains(verb) }
            let own = leading.filter(witnessed)
            if own.isEmpty, order.contains(where: { !leading.contains($0) && witnessed($0) }) { return nil }
            if !own.isEmpty { leading = own }
        }
        return [leading[0]] + order.filter { $0 != leading[0] }
    }

    /// Whether the messages behind a line say someone other than its opening names did its verb,
    /// as when Shell writes "Core fixed it" and the line says "Shell fixed the race". A message
    /// that also credits one of the names, as in "I fixed one and Core fixed the other", is fine.
    func creditsSomeoneElse(_ verb: String, names: Set<String>, in sequences: [Int]) -> Bool {
        let subjects = sequences.reduce(into: Set<String>()) { subjects, sequence in
            guard let statement = statements[sequence] else { return }
            subjects.formUnion(Self.subjects(of: verb, in: statement.text, speaker: statement.speaker,
                                             participants: participants))
        }
        return !subjects.isEmpty && subjects.isDisjoint(with: names)
    }

    /// Who `text` says did `verb`, matched by stem: the names just before it, as in "Core and Kit
    /// have fixed", or after "by", as in "fixed by Core". "I" and "we" are the speaker, and "you"
    /// is whoever was addressed, so never the speaker.
    static func subjects(of verb: String, in text: String, speaker: String?,
                         participants: Set<String>) -> Set<String> {
        let target = stem(verb)
        var subjects = Set<String>()
        for sentence in text.split(separator: "\n").flatMap({ sentences(String($0)) }) {
            let words = words(in: sentence)
            for (index, word) in words.enumerated() where stem(word) == target {
                var cursor = index - 1
                while cursor >= 0, auxiliaryWords.contains(words[cursor]) || contractionTails.contains(words[cursor]) {
                    cursor -= 1
                }
                while cursor >= 0 {
                    guard let (name, length) = name(endingAt: cursor, in: words, speaker: speaker,
                                                    participants: participants) else { break }
                    subjects.insert(name)
                    cursor -= length
                    guard cursor >= 1, ["and", "or"].contains(words[cursor]) else { break }
                    cursor -= 1
                }
                if index + 2 < words.count, words[index + 1] == "by",
                   let (name, _) = name(startingAt: index + 2, in: words, participants: participants) {
                    subjects.insert(name)
                }
            }
        }
        return subjects
    }

    private static func name(endingAt index: Int, in words: [String], speaker: String?,
                             participants: Set<String>) -> (String, Int)? {
        if index >= 1, participants.contains(words[index - 1] + " " + words[index]) {
            return (words[index - 1] + " " + words[index], 2)
        }
        if ["i", "we"].contains(words[index]) { return speaker.map { ($0.lowercased(), 1) } }
        if words[index] == "you" || participants.contains(words[index]) { return (words[index], 1) }
        return nil
    }

    private static func name(startingAt index: Int, in words: [String],
                             participants: Set<String>) -> (String, Int)? {
        if index + 1 < words.count, participants.contains(words[index] + " " + words[index + 1]) {
            return (words[index] + " " + words[index + 1], 2)
        }
        return participants.contains(words[index]) || words[index] == "you" ? (words[index], 1) : nil
    }

    /// Whether a line's verb can stand without a witness. Asking, sharing, planning or confirming is
    /// the message itself. Any other verb, like "removed" in "Lead removed the shim", can't appear
    /// only in someone else's message, though it may be the model's own word for what was said.
    func exemptPredicate(_ verb: String) -> Bool {
        Self.reportingWords.contains(verb) || Self.statementWords.contains(verb) || extraWords.contains(verb)
    }

    /// The participant names a line opens with, such as ["pixel", "kit"] for "Pixel and Kit shared
    /// files". "The user" and "the reader" are "you", and "the lead" is "lead".
    static func openingNames(_ text: String, participants: Set<String>) -> [String] {
        openingClause(text, participants: participants).names
    }

    /// The verb after a line's opening names, such as "removed" in "Lead also removed the shim".
    static func predicate(_ text: String, participants: Set<String>) -> String? {
        let clause = openingClause(text, participants: participants)
        guard !clause.names.isEmpty else { return nil }
        return clause.rest.first { !auxiliaryWords.contains($0) }
    }

    private static func openingClause(_ text: String, participants: Set<String>)
        -> (names: [String], rest: ArraySlice<String>) {
        let words = tokens(text).map { $0.lowercased() }
        var names: [String] = []
        var index = 0
        var end = 0
        while index < words.count {
            if index + 1 < words.count, words[index] == "the", ["user", "reader"].contains(words[index + 1]) {
                names.append("you")
                index += 2
            } else if index + 1 < words.count, words[index] == "the", participants.contains(words[index + 1]) {
                names.append(words[index + 1])
                index += 2
            } else if index + 1 < words.count, participants.contains(words[index] + " " + words[index + 1]) {
                names.append(words[index] + " " + words[index + 1])
                index += 2
            } else if participants.contains(words[index]) {
                names.append(words[index])
                index += 1
            } else {
                break
            }
            end = index
            if index < words.count, ["and", "or"].contains(words[index]) { index += 1 }
        }
        return (names, words[end...])
    }

    /// Summaries speak about people. "I", "we" or "our" means a message was copied, not summarized.
    static func isFirstPerson(_ text: String) -> Bool {
        tokens(text).contains { token in
            token != "US" && firstPerson.contains(token.lowercased().replacing("\u{2019}", with: "'"))
        }
    }

    /// "Lead to you: Should the beta wait?" keeps the prompt's "Speaker to Name:" framing, so it's a
    /// message copied with its header, not a summary.
    static func echoesTranscript(_ text: String) -> Bool {
        text.firstMatch(of: transcriptHeader) != nil
    }

    /// The content stems of a line, for spotting two lines that say the same thing.
    static func gist(_ text: String, participants: Set<String>) -> Set<String> {
        Set(contentWords(text, participants: participants).filter { !reportingWords.contains($0) }.map(stem))
    }

    /// Whether two gists mostly say the same thing, such as "Core confirmed the app builds as universal"
    /// and "Core verified the app builds as a universal binary".
    static func repeats(_ gist: Set<String>, _ other: Set<String>) -> Bool {
        let shared = gist.intersection(other).count
        return shared >= 2 && Double(shared) / Double(max(1, min(gist.count, other.count))) >= 0.7
    }

    /// The cited messages that back at least one of the line's words, with how many they back,
    /// strongest first and then oldest, so the first is the message the line is really about. A
    /// citation that backs nothing is dropped unless none of them do.
    func scoredSources(for text: String, cited: Set<Int>) -> [(sequence: Int, score: Int)] {
        let content = Self.contentWords(text, participants: participants)
        let scored = cited.map { sequence in
            let vocabulary = Vocabulary(evidence[sequence] ?? "")
            return (sequence: sequence, score: content.filter(vocabulary.contains).count)
        }
        let backing = scored.filter { $0.score > 0 }
        return (backing.isEmpty ? scored : backing)
            .sorted { ($0.score, -$0.sequence) > ($1.score, -$1.sequence) }
    }

    static func cleaned(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacing(/^[-•*\s]+/, with: "")
        text = text.replacing(/\s*[\[(](?:sources?:?\s*|messages?:?\s*|#)?\d+(?:\s*,\s*#?\d+)*[\])]\s*$/, with: "")
        text = text.replacing(messageReference, with: "")
        text = text.replacing(/\s+/, with: " ")
        text = text.replacing(/\s+([.,;:!?])/) { String($0.1) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func supports(_ text: String, corpus: String, participants: Set<String>,
                         extraWords: Set<String> = []) -> Bool {
        guard literalsSupported(text, corpus: corpus, names: participants) else { return false }
        let vocabulary = Vocabulary(corpus)
        let content = contentWords(text, participants: participants)
        guard !content.isEmpty else { return true }
        let supported = content.filter { word in
            reportingWords.contains(word) || extraWords.contains(word) || vocabulary.contains(word)
        }
        return Double(supported.count) / Double(content.count) >= minimumSupport
    }

    /// The lowercased words of `text` that carry meaning: not stop words, names or very short.
    static func contentWords(_ text: String, participants: Set<String>) -> [String] {
        tokens(text).map { $0.lowercased() }.filter {
            $0.count >= 3 && !stopWords.contains($0) && !participants.contains($0)
        }
    }

    /// The words of some evidence, matched exactly, by stem, or by a shared six-letter prefix.
    struct Vocabulary {
        let words: Set<String>
        let stems: Set<String>

        init(_ text: String) {
            words = Set(Grounding.words(in: text))
            stems = Set(words.map(Grounding.stem))
        }

        func contains(_ word: String) -> Bool {
            words.contains(word) || stems.contains(Grounding.stem(word)) || Grounding.sharesPrefix(word, words)
        }
    }

    /// Numbers, quoted phrases and capitalized names after the first word must all appear in
    /// `corpus`, unless they're one of `names`.
    static func literalsSupported(_ text: String, corpus: String, names: Set<String>) -> Bool {
        let lowerCorpus = corpus.lowercased()
        let flatCorpus = lowerCorpus.replacing(/\s+/, with: " ")
        let corpusWords = Set(words(in: lowerCorpus))

        for number in text.matches(of: /[A-Za-z]*\d[\w.\-\/:%]*/) {
            let value = String(number.0).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".:-/"))
            if !lowerCorpus.contains(value) { return false }
        }

        for quote in text.matches(of: /["\u{201C}\u{2018}]([^"\u{201D}\u{2019}]{2,})["\u{201D}\u{2019}]|(?:^|[^A-Za-z])'([^']{2,})'(?![A-Za-z])/) {
            guard let phrase = (quote.1 ?? quote.2).map({ String($0).lowercased().replacing(/\s+/, with: " ") }) else { continue }
            if !flatCorpus.contains(phrase.trimmingCharacters(in: .punctuationCharacters)) { return false }
        }

        for sentence in sentences(text, endingIn: ".!?:;") {
            for (index, token) in tokens(String(sentence)).enumerated() where index > 0 {
                guard token.first?.isUppercase == true else { continue }
                let lowered = token.lowercased()
                if names.contains(lowered) || corpusWords.contains(lowered) || commonCapitalized.contains(lowered) { continue }
                return false
            }
        }

        for name in namedEntities(text) where !names.contains(name) && !flatCorpus.contains(name) {
            if name.split(separator: " ").allSatisfy({ names.contains(String($0)) || corpusWords.contains(String($0)) }) { continue }
            return false
        }
        return true
    }

    /// People, places and organizations the system's language tagger finds, lowercased.
    static func namedEntities(_ text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                names.append(text[range].lowercased())
            }
            return true
        }
        return names
    }

    /// Splits after any of `terminators` that's followed by whitespace, keeping the terminators.
    static func sentences(_ text: String, endingIn terminators: String = ".!?") -> [String] {
        var sentences: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character.isWhitespace, let previous, terminators.contains(previous) {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { sentences.append(sentence) }
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { sentences.append(last) }
        return sentences
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" })
            .map { String($0).replacing(/^['\u{2019}]+|['\u{2019}]s?$/, with: "") }
            .filter { !$0.isEmpty }
    }

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// A deliberately small stemmer, so "tabs" meets "tab" and "moved" meets "movement".
    static func stem(_ word: String) -> String {
        var word = word.lowercased()
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        for suffix in ["ments", "ment", "ing", "ed", "es", "s", "ly"]
        where word.count - suffix.count >= 3 && word.hasSuffix(suffix)
            && !(suffix.hasSuffix("s") && word.hasSuffix("s" + suffix)) {
            word = String(word.dropLast(suffix.count))
            break
        }
        if word.count > 3, word.hasSuffix("e") { word.removeLast() }
        return word
    }

    static func sharesPrefix(_ word: String, _ corpusWords: Set<String>) -> Bool {
        guard word.count >= 6 else { return false }
        let prefix = word.prefix(6)
        return corpusWords.contains { $0.count >= 6 && $0.hasPrefix(prefix) }
    }

    /// Neutral verbs a summary needs to report who said what. Outcomes such as "approved", "fixed"
    /// or "shipped" are deliberately absent, so they must appear in the cited messages.
    static let reportingWords: Set<String> = [
        "ask", "asked", "asks", "asking", "share", "shared", "shares", "post", "posted", "posts",
        "say", "said", "says", "report", "reported", "reports", "note", "noted", "notes",
        "mention", "mentioned", "mentions", "suggest", "suggested", "suggests", "propose", "proposed",
        "proposes", "request", "requested", "requests", "explain", "explained", "explains",
        "describe", "described", "describes", "raise", "raised", "raises", "flag", "flagged", "flags",
        "want", "wants", "wanted", "need", "needs", "needed", "reply", "replied", "replies",
        "answer", "answered", "message", "messages", "update", "updated", "updates", "team",
        "preference", "input", "feedback", "question", "questions", "whether",
    ]

    static let commonCapitalized: Set<String> = ["i", "mac", "macos", "you"]

    /// Words that follow a name used to address someone, as in "Designer, I changed the spec" or
    /// "Kit, please check the build", rather than one listing who acted.
    static let vocativeFollowers: Set<String> = firstPerson.union([
        "you", "your", "you're", "you've", "you'll", "please", "can", "could", "would", "will",
        "thanks", "thank", "nice", "great", "good", "yes", "no", "quick", "heads", "one", "go",
        "take", "check", "see", "let", "if", "when", "re",
    ])

    /// Verbs that report what someone said, planned or agreed to rather than a result they produced.
    static let statementWords: Set<String> = [
        "plan", "plans", "planned", "planning", "intends", "intended", "will", "confirm", "confirms",
        "confirmed", "agree", "agrees", "agreed", "announce", "announces", "announced", "answer",
        "answers", "answered", "warn", "warns", "warned",
    ]

    /// What's left of a contraction once words are split on apostrophes, as in "I've fixed".
    static let contractionTails: Set<String> = ["ve", "ll", "d", "s", "re", "m"]

    /// Words that point at a request without saying anything about it.
    static let genericWords: Set<String> = [
        "pending", "outstanding", "open", "remaining", "earlier", "previous", "thing", "things",
        "something", "anything", "item", "items", "matter", "issue", "issues", "action", "actions",
        "step", "steps", "decide", "decided", "deciding", "confirmation", "confirmed", "approved",
    ]

    /// Words between a line's opening names and its verb, as in "Lead also removed" or "Ada has fixed".
    static let auxiliaryWords: Set<String> = [
        "also", "now", "then", "finally", "just", "already", "both", "all", "each", "has", "have",
        "had", "was", "were", "is", "are", "and", "successfully",
    ]

    static let firstPerson: Set<String> = [
        "i", "i'm", "i've", "i'll", "i'd", "me", "my", "mine", "we", "we're", "we've", "we'll", "we'd",
        "our", "ours", "us",
    ]

    /// "in msg 480", "(message 12)" or "seq 530": prompt numbering that means nothing to a reader.
    nonisolated(unsafe) static let messageReference =
        /\s*\(?\b(?:in |see |per |from )?(?:msgs?|messages?|seq|sequence)\.?\s*#?\d+(?:\s*(?:,|and|&)\s*#?\d+)*\)?/
            .ignoresCase()

    /// A transcript line's "[12] Lead to you, Kit:" header, as `CatchUpEntry.line` writes it.
    nonisolated(unsafe) static let transcriptHeader =
        /^(?:\[\d+\]\s*)?\p{Lu}[\p{L}\-]*(?: \p{Lu}[\p{L}\-]*)?(?: to (?:you|\p{Lu}[\p{L}\-]*)(?:, (?:you|\p{Lu}[\p{L}\-]*))*)?:\s/

    /// The vocabulary of asking someone for a reply, allowed only in the needs-you line.
    static let requestWords: Set<String> = [
        "waiting", "wait", "waits", "reply", "respond", "response", "answer", "decide", "decision",
        "choose", "choice", "pick", "confirm", "approve", "approval", "review", "input", "help",
        "between", "whether", "which", "option", "options", "go-ahead", "sign-off", "permission",
    ]

    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "onto", "about", "after", "before",
        "now", "also", "their", "them", "they", "will", "would", "should", "could", "can", "has", "have",
        "had", "was", "were", "are", "is", "been", "being", "its", "your", "you", "our", "all", "any",
        "some", "more", "most", "other", "than", "then", "there", "here", "which", "who", "what", "when",
        "where", "why", "how", "not", "but", "yet", "out", "over", "under", "again", "both", "each",
        "few", "such", "only", "own", "same", "too", "very", "just", "per", "via", "while", "until",
        "because", "between", "through", "during", "without", "within", "along", "across", "these",
        "those", "his", "her", "him", "she", "one", "two", "new", "still", "did", "does", "done", "get",
        "got", "let", "may", "might", "must", "shall", "way", "ways", "use", "used", "using", "make",
        "made", "next", "first", "last", "back", "well", "much", "many", "lot", "so", "it", "an", "a",
        "to", "of", "in", "on", "at", "by", "or", "as", "be", "if", "no", "up", "we", "us", "my", "me",
    ]
}
