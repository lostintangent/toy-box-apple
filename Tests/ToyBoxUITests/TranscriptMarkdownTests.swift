import ChannelKit
import Foundation
import SwiftUI
import Testing
import ToyBoxUI

@Suite("Shared transcript rendering inputs")
struct TranscriptMarkdownTests {
    @MainActor
    @Test func theHostSuppliesTypographyClipboardAndMentionInk() {
        let view = TranscriptMarkdown(content: "Body and `code`", bodySize: 17, codeSize: 15,
                                      lineSpacing: 4, textScale: 1.2, copyCode: { _ in },
                                      mentionInk: { _ in .purple })
        #expect(view.bodySize == 17 && view.codeSize == 15 && view.lineSpacing == 4 && view.textScale == 1.2)
        let defaults = TranscriptMarkdown(content: "", copyCode: { _ in }, mentionInk: { _ in .purple })
        #expect(defaults.bodySize == 14 && defaults.codeSize == 12 && defaults.lineSpacing == 3)
        #expect(defaults.textScale == 1)
    }

    @Test func nativeInkIsAppliedOnlyToKnownUnlinkedNonCodeMentions() throws {
        let ada = ChannelAgent(id: "ada", name: "Ada")
        var identities: [String?] = []
        let rendered = transcriptInlineMarkdown(
            "@ada @unknown `@ada` [@ada](https://example.com) @everyone", agents: [ada],
            textScale: 1.2, fontSize: 17, codeSize: 15,
            mentionInk: { agent in
                identities.append(agent?.id)
                return agent == nil ? .orange : .purple
            })
        #expect(identities == ["ada", nil])
        #expect(String(rendered.characters) == "@ada @unknown @ada @ada @everyone")
        let tinted = rendered.runs.filter { $0.foregroundColor != nil }
        #expect(tinted.map { String(rendered[$0.range].characters) } == ["@ada", "@everyone"])
        #expect(tinted.map(\.foregroundColor) == [.purple, .orange])
        #expect(tinted.allSatisfy { $0.font == .system(size: 17 * 1.2, weight: .semibold) })
        #expect(rendered.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }?.font
                == .system(size: 15 * 1.2, design: .monospaced))
        #expect(rendered.runs.first { $0.link != nil }?.link == URL(string: "https://example.com"))
    }

    @Test(arguments: [false, true])
    func highlightsClipUnicodeMatchesAcrossFragmentsAndRetainAttributes(isCurrent: Bool) throws {
        let blocks = MarkdownBlock.parse("# \u{1f44b} Caf\u{00e9}\n\n**ready** now")
        let stream = TranscriptMarkdownText(blocks)
        #expect(stream.text == "\u{1f44b} Caf\u{00e9}\nready now")
        let highlight = TranscriptFindHighlight(query: "cafe\nrea", isCurrent: isCurrent,
                                                background: .yellow, foreground: .black)
        let highlights = TranscriptMarkdownHighlights(blocks: blocks, highlight: highlight)
        let heading = highlights.applying(to: AttributedString("\u{1f44b} Caf\u{00e9}"), fragment: .init(block: 0))
        let body = transcriptInlineMarkdown("**ready** now", agents: [], mentionInk: { _ in .purple })
        let decorated = highlights.applying(to: body, fragment: .init(block: 1))
        func matches(_ text: AttributedString) -> [String] {
            text.runs.filter { $0.backgroundColor != nil }.map { String(text[$0.range].characters) }
        }
        #expect(matches(heading) == ["Caf\u{00e9}"])
        #expect(matches(decorated) == ["rea"])
        #expect(decorated.runs.first?.backgroundColor == Color.yellow.opacity(isCurrent ? 1 : 0.45))
        #expect(decorated.runs.first?.foregroundColor == .black)
        #expect(decorated.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        let unchanged = try #require(body.range(of: "dy now"))
        let retained = try #require(decorated.range(of: "dy now"))
        #expect(decorated[retained] == body[unchanged])
        #expect(highlights.applying(to: body, fragment: .init(block: 99)) == body)
    }

    @Test(arguments: [false, true], [false, true])
    func mentionContrastStopsAtTheFirstQualifyingFivePercentStep(isDark: Bool, increased: Bool) throws {
        let white = TranscriptRGB(red: 1, green: 1, blue: 1)
        let black = TranscriptRGB(red: 0, green: 0, blue: 0)
        let backgrounds = isDark ? [black, .init(red: 0.08, green: 0.08, blue: 0.08)]
            : [white, .init(red: 0.94, green: 0.94, blue: 0.94)]
        let target = isDark ? white : black
        let minimum = increased ? 7.0 : 4.5
        for identity in [white, black, .init(red: 0.2, green: 0.5, blue: 0.8),
                         .init(red: 0.9, green: 0.5, blue: 0.1), .init(red: 0.4, green: 0.7, blue: 0.4)] {
            let ink = TranscriptMentionContrast.adjusted(identity, backgrounds: backgrounds,
                                                         isDark: isDark, isContrastIncreased: increased)
            #expect(backgrounds.allSatisfy { ink.contrast(with: $0) >= minimum })
            let step = try #require((0...20).first { identity.mixed(toward: target, by: Double($0) / 20) == ink })
            if step > 0 {
                let previous = identity.mixed(toward: target, by: Double(step - 1) / 20)
                #expect(backgrounds.contains { previous.contrast(with: $0) < minimum })
            }
        }
    }

    @Test func compositingAndLuminanceKeepTheirSRGBMeaning() {
        let white = TranscriptRGB(red: 1, green: 1, blue: 1)
        let black = TranscriptRGB(red: 0, green: 0, blue: 0)
        #expect(white.under(.init(red: 1, green: 0, blue: 0, alpha: 0.25))
                == .init(red: 1, green: 0.75, blue: 0.75))
        #expect(white.contrast(with: black) == 21)
        #expect(black.contrast(with: white) == 21)
        #expect(white.luminance == 1 && black.luminance == 0)
    }
}
