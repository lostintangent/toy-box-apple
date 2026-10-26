import ChannelClient
import ChannelKit
import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class TranscriptFind {
    var isPresented = false
    var query = "" {
        didSet { if query != oldValue { changedQuery() } }
    }
    private(set) var matches: [ChannelMessage] = []
    private(set) var selectedSequence: Int?
    private(set) var revealRequest: (sequence: Int, token: UUID)?
    private(set) var isSearching = false
    private(set) var error: String?
    private(set) var ownsReadingPosition = false
    private(set) var retry = UUID()
    @ObservationIgnored private var messages: [String: ChannelMessage] = [:]
    @ObservationIgnored private var rendered: [String: String] = [:]
    @ObservationIgnored private var agents: [ChannelAgent] = []
    @ObservationIgnored private var loadedSequences: Set<Int> = []
    @ObservationIgnored private var before: Int?
    @ObservationIgnored private var hasSeededHistory = false
    @ObservationIgnored private var generation = UUID()

    var blocksRead: Bool { isPresented || ownsReadingPosition }
    var highlights: [Int: TranscriptFindHighlight] {
        guard isPresented else { return [:] }
        return Dictionary(uniqueKeysWithValues: matches.map {
            ($0.sequence, TranscriptFindHighlight(query: query, isCurrent: $0.sequence == selectedSequence))
        })
    }
    var selectedIndex: Int? { matches.firstIndex { $0.sequence == selectedSequence } }
    var countLabel: String {
        if let selectedIndex { return "\(selectedIndex + 1) of \(matches.count)" }
        return isSearching || error != nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : "No matches"
    }

    func present() {
        isPresented = true
        ownsReadingPosition = true
    }

    func close() {
        isPresented = false
        generation = UUID()
        isSearching = false
    }

    func resumeReading() { ownsReadingPosition = false }

    func prepare(messages loaded: [ChannelMessage], agents: [ChannelAgent], hasOlder: Bool) {
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

    func changedQuery() {
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

    func retryHistory() { retry = UUID() }

    struct Work: Hashable {
        let query: String
        let isPresented: Bool
        let retry: UUID
    }

    var work: Work { .init(query: query, isPresented: isPresented, retry: retry) }

    func move(_ direction: Int) {
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
    func searchOlder(history: (Int) async throws -> [ChannelMessage]) async {
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

    static func renderedText(_ message: ChannelMessage, agents: [ChannelAgent]) -> String {
        guard let system = message.system else {
            let body = message.sender.type == "agent"
                ? withoutLeadingMentions(message.text, agents: agents) : message.text
            return TranscriptMarkdownText(MarkdownBlock.parse(body)).text
        }
        return ChannelSystemText.rendered(system, agents: agents)
    }
}

struct TranscriptFindPattern {
    let query: String

    init(_ query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func ranges(in text: String) -> [Range<Int>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<Int>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: start..<text.endIndex, locale: Locale(identifier: "en_US_POSIX")) {
            guard !range.isEmpty else {
                start = text.index(after: start)
                continue
            }
            let utf16 = NSRange(range, in: text)
            result.append(utf16.location..<(utf16.location + utf16.length))
            start = range.upperBound
        }
        return result
    }
}

struct TranscriptFindHighlight: Equatable {
    let query: String
    let isCurrent: Bool

    func applying(to value: AttributedString, ranges: [Range<Int>]? = nil, offset: Int = 0) -> AttributedString {
        let plain = String(value.characters)
        let occurrences = ranges ?? TranscriptFindPattern(query).ranges(in: plain)
        let bounds = offset..<(offset + plain.utf16.count)
        var result = value
        for occurrence in occurrences {
            let lower = max(bounds.lowerBound, occurrence.lowerBound)
            let upper = min(bounds.upperBound, occurrence.upperBound)
            guard lower < upper,
                  let range = Range(NSRange(location: lower - offset, length: upper - lower), in: plain),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[start..<end].backgroundColor = Color(nsColor: .findHighlightColor).opacity(isCurrent ? 1 : 0.45)
            result[start..<end].foregroundColor = Color(nsColor: .black)
        }
        return result
    }
}

struct TranscriptFindBar: View {
    @Bindable var find: TranscriptFind
    let channelName: String
    var focusRequest: UUID
    var navigate: (Int) -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TranscriptFindField(query: $find.query, focusRequest: focusRequest, navigate: navigate, close: close)
                .frame(height: 28)
                Text(find.countLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("Matching messages: \(find.countLabel)")
                ControlGroup {
                    Button("Previous Match", systemImage: "chevron.left") { navigate(-1) }
                        .help("Previous Match (Shift-Command-G)")
                    Button("Next Match", systemImage: "chevron.right") { navigate(1) }
                        .help("Next Match (Command-G)")
                }
                .controlGroupStyle(.navigation)
                .disabled(find.matches.isEmpty)
                .accessibilityIdentifier("channel-find-navigation")
                Button("Done", action: close).frame(minHeight: 28)
                .help("Close Find")
                .accessibilityLabel("Close Find")
            }
            if let error = find.error {
                HStack {
                    Text("Couldn't search older messages").foregroundStyle(.secondary).help(error)
                    Button("Retry") { find.retryHistory() }.buttonStyle(.borderless)
                }
                .font(.caption)
            } else if find.isSearching {
                Text("Searching older messages...").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in \(channelName)")
        .onExitCommand(perform: close)
    }
}

private struct TranscriptFindField: NSViewRepresentable {
    @Binding var query: String
    let focusRequest: UUID
    var navigate: (Int) -> Void
    var close: () -> Void

    func makeNSView(context: Context) -> FindField {
        let field = FindField()
        field.placeholderString = "Search this channel"
        field.setAccessibilityIdentifier("channel-find-field")
        field.setAccessibilityLabel("Search this channel")
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.onAttach = { [weak coordinator = context.coordinator] in coordinator?.focus($0) }
        return field
    }

    func updateNSView(_ field: FindField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
        context.coordinator.focus(field)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class FindField: NSSearchField {
        var onAttach: ((FindField) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onAttach?(self) }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TranscriptFindField
        private var focusedRequest: UUID?
        init(_ parent: TranscriptFindField) { self.parent = parent }

        func focus(_ field: NSSearchField) {
            guard field.window != nil, focusedRequest != parent.focusRequest else { return }
            focusedRequest = parent.focusRequest
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }

        @objc func changed(_ field: NSSearchField) { parent.query = field.stringValue }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { changed(field) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.cancelOperation(_:)) {
                parent.close()
                return true
            }
            if command == #selector(NSResponder.insertNewline(_:))
                || command == #selector(NSResponder.insertLineBreak(_:)) {
                let previous = command == #selector(NSResponder.insertLineBreak(_:))
                    || NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                parent.navigate(previous ? -1 : 1)
                return true
            }
            return false
        }
    }
}
