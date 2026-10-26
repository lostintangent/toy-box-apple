import AppKit
import ChannelClient
import ChannelKit
import Foundation
import SwiftUI
import ToyBoxUI
import Testing
@testable import ToyBoxDesktop

@MainActor
@Suite("Channel message Find")
struct TranscriptFindTests {
    private func message(_ sequence: Int, _ text: String, sender: ChannelMessageSender = .user) -> ChannelMessage {
        .init(id: "find-\(sequence)", sequence: sequence, timestamp: "2026-10-24T12:00:00Z",
              sender: sender, content: .text(text))
    }

    private func make(_ messages: [ChannelMessage], hasOlder: Bool = false) -> TranscriptFind {
        let find = TranscriptFind()
        find.prepare(messages: messages, agents: [.lead(id: "lead")], hasOlder: hasOlder)
        find.present()
        return find
    }

    @Test func highlightsPersistForEveryMatchAndClearWithoutLosingTheQuery() throws {
        let find = make([message(1, "hit hit"), message(2, "no match"), message(3, "HIT")])
        find.query = "hit"
        #expect(find.highlights.keys.sorted() == [1, 3])
        #expect(find.highlights[1]?.isCurrent == true)
        #expect(find.highlights[3]?.isCurrent == false)
        let first = try #require(find.highlights[1])
        #expect(highlighted(first.applying(to: AttributedString("hit hit"))) == ["hit", "hit"])
        find.move(1)
        #expect(find.highlights[1]?.isCurrent == false)
        #expect(find.highlights[3]?.isCurrent == true)
        find.close()
        #expect(find.highlights.isEmpty)
        #expect(find.query == "hit")
        find.present()
        #expect(find.highlights.keys.sorted() == [1, 3])
        find.query = ""
        #expect(find.highlights.isEmpty)
    }

    @Test func decorationPreservesMarkdownLinksCodeMentionsAndUnmatchedAttributes() throws {
        let agents = [ChannelAgent.lead(id: "lead")]
        let source = "**Caf\u{00e9}** [CAFE](https://hidden.example) `cafe` @lead and plain."
        let plain = transcriptInlineMarkdown(source, agents: agents)
        let decorated = TranscriptFindHighlight(query: "cafe", isCurrent: true).applying(to: plain)
        #expect(String(decorated.characters) == String(plain.characters))
        #expect(highlighted(decorated) == ["Caf\u{00e9}", "CAFE", "cafe"])
        #expect(decorated.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(decorated.runs.first { $0.link != nil }?.link == URL(string: "https://hidden.example"))
        #expect(decorated.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }?.font
                == .system(size: 12, design: .monospaced))
        let mention = try #require(decorated.range(of: "@lead"))
        let original = try #require(plain.range(of: "@lead"))
        #expect(decorated[mention] == plain[original])
    }

    @Test func theIndexAndHighlightsShareOneStreamAcrossMarkdownBlocksAndTableCells() throws {
        let source = "# Caf\u{00e9}\n\n**ready** [now](https://hidden.example)\n\n"
            + "```swift\n  **literal** cafe\n```\n\n"
            + "| First | Second |\n| --- | --- |\n| caf\u{00e9} | ready |\n\n2. cafe ready"
        let blocks = MarkdownBlock.parse(source)
        let stream = TranscriptMarkdownText(blocks)
        #expect(stream.text == "Caf\u{00e9}\nready now\n  **literal** cafe\nFirst  Second\ncaf\u{00e9}  ready\n2. cafe ready")
        #expect(TranscriptFind.renderedText(message(1, source), agents: []) == stream.text)

        let crossBlock = TranscriptMarkdownHighlights(blocks: blocks,
            highlight: .init(query: "cafe\nready", isCurrent: true))
        #expect(highlighted(crossBlock.applying(to: AttributedString("Caf\u{00e9}"), fragment: .init(block: 0)))
                == ["Caf\u{00e9}"])
        #expect(highlighted(crossBlock.applying(to: transcriptInlineMarkdown("**ready** now", agents: []),
                                               fragment: .init(block: 1))) == ["ready"])
        let crossCell = TranscriptMarkdownHighlights(blocks: blocks,
            highlight: .init(query: "cafe  ready", isCurrent: false))
        #expect(highlighted(crossCell.applying(to: AttributedString("caf\u{00e9}"),
                                              fragment: .init(block: 3, row: 1, column: 0))) == ["caf\u{00e9}"])
        #expect(highlighted(crossCell.applying(to: AttributedString("ready"),
                                              fragment: .init(block: 3, row: 1, column: 1))) == ["ready"])
        let code = TranscriptMarkdownHighlights(blocks: blocks,
            highlight: .init(query: "**literal**", isCurrent: true))
        #expect(highlighted(code.applying(to: AttributedString("  **literal** cafe"),
                                         fragment: .init(block: 2))) == ["**literal**"])
        let marker = TranscriptMarkdownHighlights(blocks: blocks,
            highlight: .init(query: "2. cafe", isCurrent: true))
        #expect(highlighted(marker.applying(to: AttributedString("2."), fragment: .init(block: 4))) == ["2."])
        #expect(highlighted(marker.applying(to: AttributedString("cafe ready"),
                                           fragment: .init(block: 4, column: 1))) == ["cafe"])
    }

    @Test func findDecorationsUseSystemColorAndKeepTextContrastInBothAppearances() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                for isCurrent in [false, true] {
                    let decorated = TranscriptFindHighlight(query: "hit", isCurrent: isCurrent)
                        .applying(to: AttributedString("hit"))
                    guard let run = decorated.runs.first, let fill = run.backgroundColor,
                          let background = TranscriptRGB(NSColor.textBackgroundColor),
                          let overlay = TranscriptRGB(fill),
                          let ink = run.foregroundColor.flatMap(TranscriptRGB.init) else {
                        Issue.record("Find colors must resolve in the requested appearance.")
                        continue
                    }
                    #expect(fill == Color(nsColor: .findHighlightColor).opacity(isCurrent ? 1 : 0.45))
                    #expect(ink.contrast(with: background.under(overlay)) >= 4.5)
                }
            }
        }
    }

    @Test func onlyMatchingRowsAndAgentMessagesChangeWithTheQuery() throws {
        let agent = ChannelAgent.lead(id: "lead")
        let messages = [message(1, "hit hit", sender: .agent("lead")),
                        message(2, "no result", sender: .agent("lead")), message(3, "unrelated")]
        let rows = transcriptRows(messages, lead: agent, members: [])
        let api = try ChannelAPI(serverURL: "https://find.invalid")
        let store = ChannelStore(id: "find", api: api, sendJournal: nil)
        let context = TranscriptRowContext(agents: [agent], channelID: "find", historyStart: 1, api: api)
        func content(_ row: TranscriptRow, query: String) -> TranscriptRowContent {
            .init(row: row, context: context, statusReactions: [:], highlightedSequence: nil, catchUp: nil,
                  store: store, expandedMessageIds: [],
                  findHighlights: [1: .init(query: query, isCurrent: true)], onSetExpanded: { _, _ in })
        }
        let run = try #require(rows.first)
        let user = try #require(rows.last)
        #expect(content(run, query: "hit") != content(run, query: "hi"))
        #expect(content(user, query: "hit") == content(user, query: "hi"))
        #expect(content(user, query: "hit").findHighlights.isEmpty)
        guard case .agent(_, let entries) = run.content else {
            Issue.record("The fixture must group both agent messages into one run.")
            return
        }
        try #require(entries.count == 2)
        let interaction = ChannelInteraction()
        func child(_ entry: AgentRunEntry, query: String) -> TranscriptAgentMessage {
            .init(entry: entry, agent: agent, agents: [agent], api: api, interaction: interaction,
                  statusReactions: [], expanded: false,
                  findHighlight: entry.message.sequence == 1 ? .init(query: query, isCurrent: true) : nil,
                  onSetExpanded: { _, _ in })
        }
        #expect(child(entries[0], query: "hit") != child(entries[0], query: "hi"))
        #expect(child(entries[1], query: "hit") == child(entries[1], query: "hi"))
    }

    private func highlighted(_ text: AttributedString) -> [String] {
        text.runs.filter { $0.backgroundColor != nil }.map { String(text[$0.range].characters) }
    }
}
