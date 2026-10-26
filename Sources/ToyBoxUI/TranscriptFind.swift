import ChannelClient
import ChannelKit
import Foundation
import Observation

@MainActor @Observable
public final class TranscriptFind {
    public init() {}

    public var isPresented = false
    public var query = "" {
        didSet { if query != oldValue { changedQuery() } }
    }
    public private(set) var matches: [ChannelMessage] = []
    public private(set) var selectedSequence: Int?
    public private(set) var revealRequest: (sequence: Int, token: UUID)?
    public private(set) var isSearching = false
    public private(set) var error: String?
    private(set) var ownsReadingPosition = false
    private(set) var retry = UUID()
    @ObservationIgnored private var messages: [String: ChannelMessage] = [:]
    @ObservationIgnored private var rendered: [String: String] = [:]
    @ObservationIgnored private var agents: [ChannelAgent] = []
    @ObservationIgnored private var loadedSequences: Set<Int> = []
    @ObservationIgnored private var before: Int?
    @ObservationIgnored private var hasSeededHistory = false
    @ObservationIgnored private var generation = UUID()

    public var blocksRead: Bool { isPresented || ownsReadingPosition }
    var selectedIndex: Int? { matches.firstIndex { $0.sequence == selectedSequence } }
    public var countLabel: String {
        if let selectedIndex { return "\(selectedIndex + 1) of \(matches.count)" }
        return isSearching || error != nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : "No matches"
    }

    public func present() {
        isPresented = true
        ownsReadingPosition = true
    }

    public func close() {
        isPresented = false
        generation = UUID()
        isSearching = false
    }

    public func resumeReading() { ownsReadingPosition = false }

    public func prepare(messages loaded: [ChannelMessage], agents: [ChannelAgent], hasOlder: Bool) {
        loadedSequences = Set(loaded.map(\.sequence))
        if self.agents != agents {
            self.agents = agents
            rendered = [:]
        }
        for message in loaded where message.sequence > 0 {
            if messages[message.id] != message { rendered[message.id] = nil }
            messages[message.id] = message
        }
        if !hasSeededHistory {
            let oldest = loaded.map(\.sequence).filter { $0 > 0 }.min()
            before = hasOlder ? oldest.flatMap { $0 > 1 ? $0 : nil } : nil
            hasSeededHistory = !loaded.isEmpty || !hasOlder
        }
        updateMatches()
    }

    private func changedQuery() {
        selectedSequence = nil
        revealRequest = nil
        error = nil
        generation = UUID()
        isSearching = isPresented && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && before != nil
        updateMatches()
        if let sequence = selectedSequence, loadedSequences.contains(sequence) {
            revealRequest = (sequence, UUID())
        }
    }

    public func retryHistory() { retry = UUID() }

    public struct Work: Hashable {
        public let query: String
        public let isPresented: Bool
        public let retry: UUID
    }

    public var work: Work { .init(query: query, isPresented: isPresented, retry: retry) }

    public func move(_ direction: Int) {
        guard !matches.isEmpty else { return }
        if revealRequest?.sequence == selectedSequence {
            let current = selectedIndex ?? (direction > 0 ? -1 : 0)
            let index = (current + direction % matches.count + matches.count) % matches.count
            selectedSequence = matches[index].sequence
        }
        if let selectedSequence { revealRequest = (selectedSequence, UUID()) }
        ownsReadingPosition = true
    }

    /// Reads history into this search only. Selection reveals through the channel's normal path.
    public func searchOlder(history: (Int) async throws -> [ChannelMessage]) async {
        guard isPresented, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = UUID()
        generation = token
        error = nil
        isSearching = before != nil
        defer { if generation == token { isSearching = false } }
        do {
            // Loaded matches appear synchronously. Only the network traversal is debounced.
            try await Task.sleep(for: .milliseconds(200))
            while let cursor = before {
                try Task.checkCancellation()
                let page = try await history(cursor)
                guard generation == token, !Task.isCancelled else { return }
                guard page.allSatisfy({ $0.sequence > 0 && $0.sequence < cursor }) else {
                    throw ChannelAPIError.invalidEvent("history")
                }
                for message in page where messages[message.id] == nil {
                    messages[message.id] = message
                }
                let oldest = page.map(\.sequence).min()
                before = oldest.flatMap { $0 > 1 ? $0 : nil }
                updateMatches()
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func updateMatches() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            matches = []
            selectedSequence = nil
            return
        }
        matches = messages.values.filter { message in
            let text: String
            if let cached = rendered[message.id] { text = cached }
            else {
                text = Self.renderedText(message, agents: agents)
                rendered[message.id] = text
            }
            return !TranscriptFindPattern(needle).ranges(in: text).isEmpty
        }.sorted { $0.sequence < $1.sequence }
        if !matches.contains(where: { $0.sequence == selectedSequence }) {
            selectedSequence = matches.first?.sequence
        }
    }

    public static func renderedText(_ message: ChannelMessage, agents: [ChannelAgent]) -> String {
        guard let system = message.system else {
            let body = message.sender.type == "agent"
                ? withoutLeadingMentions(message.text, agents: agents) : message.text
            return TranscriptMarkdownText(MarkdownBlock.parse(body)).text
        }
        return ChannelSystemText.rendered(system, agents: agents)
    }
}
