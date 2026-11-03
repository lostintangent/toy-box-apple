import ChannelKit
import Foundation
import SwiftUI
import Testing
@testable import ToyBoxUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
        #expect(defaults.textScale == 1 && defaults.preservesLineBreaks)
    }

    @MainActor
    @Test func documentsJoinSoftWrapsWithoutChangingMessagesOrExplicitHardBreaks() {
        let source = "Wrapped\nsource  \nkeeps this break\\\nand this one\nat the end"
        let message = TranscriptMarkdown(content: source, copyCode: { _ in }, mentionInk: { _ in .purple })
        let document = TranscriptMarkdown(content: source, preservesLineBreaks: false,
                                          copyCode: { _ in }, mentionInk: { _ in .purple })
        #expect(message.inlineText(source) == source)
        let joined = document.inlineText(source)
        #expect(joined == "Wrapped source  \nkeeps this break\\\nand this one at the end")
        #expect(joined.utf16.count == source.utf16.count)
    }

    @MainActor
    @Test func wrappedListTextUsesTheSameBreakPolicyAsParagraphs() throws {
        let source = "- **Choose** one\n  next line  \n  explicit break\n- Another item"
        let blocks = MarkdownBlock.parse(source)
        guard case .listItem(_, let text, _) = try #require(blocks.first).kind else {
            Issue.record("Expected a list item")
            return
        }
        let message = TranscriptMarkdown(content: source, copyCode: { _ in }, mentionInk: { _ in .purple })
        let document = TranscriptMarkdown(content: source, preservesLineBreaks: false,
                                          copyCode: { _ in }, mentionInk: { _ in .purple })
        #expect(text == "**Choose** one\nnext line  \nexplicit break")
        #expect(message.inlineText(text) == text)
        #expect(document.inlineText(text) == "**Choose** one next line  \nexplicit break")
        #expect(document.inlineText(text).utf16.count == text.utf16.count)
    }

    @MainActor
    @Test(arguments: [1, 2, 3])
    func onlyPrimaryHeadingsHaveANativeRule(level: Int) throws {
        let heading = TranscriptMarkdown(content: "\(String(repeating: "#", count: level)) H",
                                         copyCode: { _ in }, mentionInk: { _ in .purple })
            .foregroundStyle(.black)
            .environment(\.colorScheme, .light)
            .frame(width: 320, alignment: .leading)
            .background(.white)
        let image = try ownBitmap(heading)
        let x = image.width * 3 / 4
        let hasRule = (0..<image.height).contains { y in
            let index = (y * image.width + x) * 4
            return (0..<3).allSatisfy { image.pixels[index + $0] < 252 }
        }
        #expect(hasRule == (level <= 2))
    }

    @MainActor
    @Test(arguments: [1, 2, 3], [CGFloat(1), 1.2])
    func onlyPrimaryHeadingsAfterAnotherBlockGetExtraTopSpace(level: Int, scale: CGFloat) {
        let heading = "\(String(repeating: "#", count: level)) Heading"
        let body = "Paragraph before the heading."
        func height(_ source: String) -> CGFloat {
            fittingHeight(
                TranscriptMarkdown(content: source, textScale: scale, copyCode: { _ in },
                                   mentionInk: { _ in .purple }), width: 380)
        }
        let ordinaryGap = 10 * scale
        let extra = level <= 2 ? 8 * scale : 0
        #expect(abs(height("\(body)\n\n\(heading)") - height(body) - height(heading)
                    - ordinaryGap - extra) <= 1)
        #expect(abs(height("\(heading)\n\n\(body)") - height(heading) - height(body)
                    - ordinaryGap) <= 1)
        #expect(abs(height("\(body)\n\n- List item") - height(body) - height("- List item")
                    - ordinaryGap) <= 1)
    }

    @MainActor
    @Test(arguments: [CGFloat(1), 1.2])
    func dividerSpacingStaysBetweenBlocksAndNeverAddsOuterPadding(scale: CGFloat) {
        let body = "Paragraph"
        func height(_ source: String) -> CGFloat {
            fittingHeight(
                TranscriptMarkdown(content: source, textScale: scale, copyCode: { _ in },
                                   mentionInk: { _ in .purple }), width: 380)
        }
        let gap = 10 * scale + 4
        #expect(abs(height("---\n\n\(body)") - height("---") - height(body) - gap) <= 1)
        #expect(abs(height("\(body)\n\n---") - height(body) - height("---") - gap) <= 1)
        #expect(abs(height("\(body)\n\n---\n\n\(body)")
                    - height(body) * 2 - height("---") - gap * 2) <= 1)
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

    @Test func findTextKeepsNumberedAndTaskMarkersWithoutNotificationTrimming() {
        let blocks = MarkdownBlock.parse("1. [x] **Done**\n  - Nested [note](https://example.test)")
        let projection = TranscriptMarkdownText(blocks)
        #expect(projection.text == "\u{2611} Done\n\u{2022} Nested note")
        #expect(projection.offsets[.init(block: 0)] == 0)
        #expect(projection.offsets[.init(block: 0, column: 1)] == 2)
        #expect(projection.offsets[.init(block: 1, column: 1)] == 9)
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

    @MainActor
    @Test(arguments: [false, true], [CGFloat(1), 1.2, 1.5])
    func wrappedTableCellsKeepBothVerticalInsets(selectable: Bool, scale: CGFloat) {
        let rows = [
            ["Relationship that deliberately wraps across multiple lines in a header cell", "Target"],
            ["Inline navigation bar's bottom safe-area edge to the first purpose text", "12pt"],
            ["A second wrapping row that has enough text to span several full lines in this bounded cell", "16pt"],
        ]
        let markdown = rows.enumerated().map { index, row in
            (index == 1 ? "| --- | --- |\n" : "") + "| " + row.joined(separator: " | ") + " |"
        }.joined(separator: "\n")
        let expected = rows.enumerated().reduce(CGFloat.zero) { height, row in
            height + row.element.map {
                fittingHeight(Text($0)
                    .font(.system(size: 13 * scale, weight: row.offset == 0 ? .semibold : .regular))
                    .lineSpacing(3 * scale)
                    .fixedSize(horizontal: false, vertical: true), width: 280)
            }.max()! + 14
        }
        for width in [CGFloat(260), 400, 700] {
            let actual = fittingHeight(
                TranscriptMarkdown(content: markdown, selectable: selectable, textScale: scale,
                                   copyCode: { _ in }, mentionInk: { _ in .purple }), width: width)
            #expect(abs(actual - expected) <= 1)
        }

        let singleLine = fittingHeight(Text("12pt").font(.system(size: 13 * scale)), width: 280)
        #expect(expected > 3 * (singleLine + 14))
    }

    @MainActor
    @Test(arguments: [CGFloat(720), 1_400])
    func aShortTablesBorderHugsItsColumnsInAWideLane(width: CGFloat) throws {
        let markdown = TranscriptMarkdown(content: "", selectable: false,
                                          copyCode: { _ in }, mentionInk: { _ in .purple })
        let content = markdown.table([["A", "B"], ["1", "2"]], block: 0)
            .foregroundStyle(.black)
            .environment(\.colorScheme, .light)
            .frame(width: width, height: 120, alignment: .topLeading)
            .background(.white)
        let image = try ownBitmap(content)
        let bytes = image.pixels
        func containsTableInk(at x: Int) -> Bool {
            return (0..<image.height).contains { y in
                let offset = (y * image.width + x) * 4
                return min(bytes[offset], bytes[offset + 1], bytes[offset + 2]) < 252
            }
        }
        #expect(containsTableInk(at: Int(CGFloat(image.width) * 0.05)))
        #expect(!containsTableInk(at: Int(CGFloat(image.width) * 0.75)))
        let rightEdge = try #require((0..<image.width).last(where: containsTableInk))
        #expect((167...168).contains(rightEdge))
    }

    @MainActor
    @Test func tableFillAndFinalRowStayInsideTheRoundedBorder() throws {
        let markdown = TranscriptMarkdown(content: "", selectable: false,
                                          copyCode: { _ in }, mentionInk: { _ in .purple })
        let content = markdown.table([["A", "B"], ["1", "2"]], block: 0)
            .foregroundStyle(.black)
            .environment(\.colorScheme, .light)
            .background(.white)
        let image = try ownBitmap(content)
        let bytes = image.pixels
        for x in [0, image.width - 1] {
            for y in [0, image.height - 1] {
                let offset = (y * image.width + x) * 4
                #expect((0..<3).allSatisfy { bytes[offset + $0] >= 254 })
            }
        }
        #expect(bytes[(10 * image.width + 10) * 4] < 252)
    }

    /// Draws into the test's own bitmap at the default scale. `ImageRenderer.cgImage` returns an image-provider
    /// CGImage that rasterizes through an IOSurface on first draw, the path that failed CI (t510 and t603).
    /// Both callers fill an opaque white background, so a transparent pixel marks an incomplete render.
    @MainActor
    private func ownBitmap(_ content: some View) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        let renderer = ImageRenderer(content: content)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var image: (width: Int, height: Int, pixels: [UInt8])?
        renderer.render(rasterizationScale: 1) { size, draw in
            let width = Int(size.width.rounded(.up))
            let height = Int(size.height.rounded(.up))
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                draw(context)
            }
            image = (width, height, pixels)
        }
        let result = try #require(image)
        let opaque = stride(from: 3, to: result.pixels.count, by: 4).allSatisfy { result.pixels[$0] == 255 }
        try #require(opaque, "Incomplete render: an opaque background left transparent pixels.")
        return result
    }

    @MainActor
    private func fittingHeight(_ content: some View, width: CGFloat) -> CGFloat {
        #if os(macOS)
        let host = NSHostingView(rootView: content.frame(width: width).fixedSize(horizontal: false, vertical: true))
        return host.fittingSize.height
        #else
        let host = UIHostingController(rootView: content.frame(width: width).fixedSize(horizontal: false, vertical: true))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        #endif
    }
}
