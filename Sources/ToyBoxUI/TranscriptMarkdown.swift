import ChannelKit
import Foundation
import SwiftUI

public struct TranscriptMarkdown: View {
    public let content: String
    public var agents: [ChannelAgent]
    public var baseURL: URL?
    /// Each selectable `Text` mounts its own platform text view, which is most of what a long
    /// message costs to scroll into view, so transcript rows turn this on when the pointer first
    /// reaches them.
    public var selectable: Bool
    public var findHighlight: TranscriptFindHighlight?
    public var bodySize: CGFloat
    public var codeSize: CGFloat
    public var lineSpacing: CGFloat
    public var textScale: CGFloat
    private let copyCode: (String) -> Void
    private let mentionInk: (ChannelAgent?) -> Color
    public init(content: String, agents: [ChannelAgent] = [], baseURL: URL? = nil,
                selectable: Bool = true, findHighlight: TranscriptFindHighlight? = nil,
                bodySize: CGFloat = 14, codeSize: CGFloat = 12, lineSpacing: CGFloat = 3,
                textScale: CGFloat = 1,
                copyCode: @escaping (String) -> Void, mentionInk: @escaping (ChannelAgent?) -> Color) {
        self.content = content
        self.agents = agents
        self.baseURL = baseURL
        self.selectable = selectable
        self.findHighlight = findHighlight
        self.bodySize = bodySize
        self.codeSize = codeSize
        self.lineSpacing = lineSpacing
        self.textScale = textScale
        self.copyCode = copyCode
        self.mentionInk = mentionInk
    }

    public var body: some View {
        let blocks = MarkdownBlock.parse(content)
        let highlights = findHighlight.map { TranscriptMarkdownHighlights(blocks: blocks, highlight: $0) }
        Group {
            // Most messages are one paragraph, so they skip the block stack.
            if blocks.count == 1, case .paragraph(let text) = blocks[0].kind {
                blockView(.init(id: 0, kind: .paragraph(text)), highlights: highlights)
            } else {
                VStack(alignment: .leading, spacing: 10 * textScale) {
                    ForEach(blocks) { block in
                        blockView(block, highlights: highlights)
                    }
                }
            }
        }
        .font(.system(size: bodySize * textScale))
        .lineSpacing(lineSpacing * textScale)
        .modifier(TranscriptTextSelection(enabled: selectable))
        .environment(\.openURL, OpenURLAction { url in
            let resolved = url.scheme == nil
                ? baseURL.flatMap { URL(string: url.relativeString, relativeTo: $0)?.absoluteURL } : url
            guard let resolved, ["http", "https", "mailto"].contains(resolved.scheme?.lowercased() ?? "") else {
                return .discarded
            }
            return .systemAction(resolved)
        })
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, highlights: TranscriptMarkdownHighlights?) -> some View {
        switch block.kind {
        case .paragraph(let text):
            Text(inline(text, fragment: .init(block: block.id), highlights: highlights))
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            let size: CGFloat = level == 1 ? 23 : level == 2 ? 19 : 16
            Text(inline(text, size: size, fragment: .init(block: block.id), highlights: highlights))
                .font(.system(size: size * textScale, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(highlights?.applying(to: AttributedString(marker), fragment: .init(block: block.id))
                     ?? AttributedString(marker)).foregroundStyle(ChannelInk.secondary).textSelection(.disabled)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(inline(text, fragment: .init(block: block.id, column: 1), highlights: highlights))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                Text(inline(text, fragment: .init(block: block.id), highlights: highlights)).foregroundStyle(ChannelInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(language.isEmpty ? "Code" : language).foregroundStyle(ChannelInk.secondary)
                        .textSelection(.disabled)
                    Spacer(minLength: 12)
                    Button("Copy Code", systemImage: "doc.on.doc") {
                        copyCode(code)
                    }
                    .buttonStyle(TranscriptCopyCodeButtonStyle())
                    .help("Copy code")
                }
                .font(.system(size: 11 * textScale))
                // A nested scroll view is costly to build, so only a block too wide to fit gets one.
                ViewThatFits(in: .horizontal) {
                    codeText(code, block: block.id, highlights: highlights)
                    ScrollView(.horizontal) {
                        codeText(code, block: block.id, highlights: highlights)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .table(let rows):
            ScrollView(.horizontal) {
                table(rows, block: block.id, highlights: highlights)
            }
            // Preserve the viewport's flexibility without stretching the measured rows.
            .frame(maxHeight: .infinity, alignment: .topLeading)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    func table(_ rows: [[String]], block: Int, highlights: TranscriptMarkdownHighlights? = nil) -> some View {
        TranscriptMarkdownTableLayout(columns: rows.map(\.count).max() ?? 0) {
            ForEach(rows.indices, id: \.self) { row in
                ForEach(0..<(rows.map(\.count).max() ?? 0), id: \.self) { column in
                    Text(inline(column < rows[row].count ? rows[row][column] : "", size: 13,
                                fragment: .init(block: block, row: row, column: column), highlights: highlights))
                        .font(.system(size: 13 * textScale, weight: row == 0 ? .semibold : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(row == 0 ? Color.primary.opacity(0.05) : .clear)
                        .overlay(alignment: .bottom) {
                            if row + 1 < rows.count { Divider() }
                        }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func codeText(_ code: String, block: Int, highlights: TranscriptMarkdownHighlights?) -> some View {
        let text = highlights.map { Text($0.applying(to: AttributedString(code), fragment: .init(block: block))) }
            ?? Text(verbatim: code)
        return text
            .font(.system(size: codeSize * textScale, design: .monospaced))
            .fixedSize(horizontal: true, vertical: true)
    }

    private func inline(_ text: String, size: CGFloat? = nil, fragment: TranscriptMarkdownText.Fragment,
                        highlights: TranscriptMarkdownHighlights?) -> AttributedString {
        let result = transcriptInlineMarkdown(text, agents: agents, textScale: textScale,
                                              fontSize: size ?? bodySize, codeSize: codeSize,
                                              mentionInk: mentionInk)
        return highlights?.applying(to: result, fragment: fragment) ?? result
    }
}

private struct TranscriptMarkdownTableLayout: Layout {
    let columns: Int

    struct Cache {
        var widths: [CGFloat]
        var heights: [CGFloat]
    }

    func makeCache(subviews: Subviews) -> Cache {
        guard columns > 0 else { return Cache(widths: [], heights: []) }
        var widths = Array(repeating: CGFloat(84), count: columns)
        for index in subviews.indices {
            let column = index % columns
            widths[column] = max(widths[column], min(300, subviews[index].sizeThatFits(.unspecified).width))
        }
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + columns - 1) / columns)
        for index in subviews.indices {
            // A flexible Grid frame reports its unwrapped height for an unspecified width.
            // Measure again at the final column width before choosing the row's height.
            let size = subviews[index].sizeThatFits(.init(width: widths[index % columns], height: nil))
            heights[index / columns] = max(heights[index / columns], size.height)
        }
        return Cache(widths: widths, heights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        CGSize(width: cache.widths.reduce(0, +), height: cache.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var origin = bounds.origin
        for index in subviews.indices {
            let column = index % columns
            let row = index / columns
            subviews[index].place(at: origin, anchor: .topLeading,
                                 proposal: .init(width: cache.widths[column], height: cache.heights[row]))
            if column + 1 == columns {
                origin.x = bounds.minX
                origin.y += cache.heights[row]
            } else {
                origin.x += cache.widths[column]
            }
        }
    }
}

/// One rendered stream with offsets into each independently laid-out Text, including table cells.
public struct TranscriptMarkdownText {
    public struct Fragment: Hashable {
        public var block: Int
        public var row: Int
        public var column: Int

        public init(block: Int, row: Int = 0, column: Int = 0) {
            self.block = block
            self.row = row
            self.column = column
        }
    }

    public private(set) var text = ""
    public private(set) var offsets: [Fragment: Int] = [:]

    public init(_ blocks: [MarkdownBlock]) {
        for block in blocks {
            if case .rule = block.kind { continue }
            if !text.isEmpty { text += "\n" }
            switch block.kind {
            case .paragraph(let value), .heading(_, let value), .quote(let value):
                append(parsedTranscriptInlineMarkdown(value), fragment: .init(block: block.id))
            case .listItem(let marker, let value, _):
                append(AttributedString(marker), fragment: .init(block: block.id))
                text += " "
                append(parsedTranscriptInlineMarkdown(value), fragment: .init(block: block.id, column: 1))
            case .code(_, let code):
                append(AttributedString(code), fragment: .init(block: block.id))
            case .table(let rows):
                for (row, cells) in rows.enumerated() {
                    if row > 0 { text += "\n" }
                    for (column, cell) in cells.enumerated() {
                        if column > 0 { text += "  " }
                        append(parsedTranscriptInlineMarkdown(cell),
                               fragment: .init(block: block.id, row: row, column: column))
                    }
                }
            case .rule:
                break
            }
        }
    }

    private mutating func append(_ value: AttributedString, fragment: Fragment) {
        offsets[fragment] = text.utf16.count
        text += String(value.characters)
    }
}

public struct TranscriptMarkdownHighlights {
    public let highlight: TranscriptFindHighlight
    public let document: TranscriptMarkdownText
    public let ranges: [Range<Int>]

    public init(blocks: [MarkdownBlock], highlight: TranscriptFindHighlight) {
        self.highlight = highlight
        document = TranscriptMarkdownText(blocks)
        ranges = TranscriptFindPattern(highlight.query).ranges(in: document.text)
    }

    public func applying(to value: AttributedString, fragment: TranscriptMarkdownText.Fragment) -> AttributedString {
        guard let offset = document.offsets[fragment] else { return value }
        return highlight.applying(to: value, ranges: ranges, offset: offset)
    }
}

private struct TranscriptTextSelection: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content }
    }
}

/// Draws Copy Code like a borderless button, without the AppKit control that costs every code
/// block about a millisecond to build.
private struct TranscriptCopyCodeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.primary : ChannelInk.secondary)
            .contentShape(Rectangle())
    }
}

/// An opaque sRGB color for contrast arithmetic.
public struct TranscriptRGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }

    /// This color with `layer` composited over it.
    public func under(_ layer: TranscriptRGB) -> TranscriptRGB {
        TranscriptRGB(red: layer.red * layer.alpha + red * (1 - layer.alpha),
                      green: layer.green * layer.alpha + green * (1 - layer.alpha),
                      blue: layer.blue * layer.alpha + blue * (1 - layer.alpha))
    }

    public func mixed(toward target: TranscriptRGB, by amount: Double) -> TranscriptRGB {
        TranscriptRGB(red: red + (target.red - red) * amount, green: green + (target.green - green) * amount,
                      blue: blue + (target.blue - blue) * amount)
    }

    public var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrast(with other: TranscriptRGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

public enum TranscriptMentionContrast {
    public static func adjusted(_ identity: TranscriptRGB, backgrounds: [TranscriptRGB],
                                isDark: Bool, isContrastIncreased: Bool) -> TranscriptRGB {
        let target = isDark ? TranscriptRGB(red: 1, green: 1, blue: 1) : TranscriptRGB(red: 0, green: 0, blue: 0)
        let minimumContrast = isContrastIncreased ? 7.0 : 4.5
        for step in 0..<20 {
            let candidate = identity.mixed(toward: target, by: Double(step) / 20)
            if backgrounds.allSatisfy({ candidate.contrast(with: $0) >= minimumContrast }) { return candidate }
        }
        return target
    }
}

// Hoisted so rendering a row doesn't compile its patterns again for every line or message.
nonisolated(unsafe) private let inlineMentionPattern = /(?:^|[^a-zA-Z0-9-])@([a-zA-Z0-9][a-zA-Z0-9-]*)/

public func transcriptInlineMarkdown(_ text: String, agents: [ChannelAgent], textScale: CGFloat = 1,
                                     fontSize: CGFloat = 14, codeSize: CGFloat = 12,
                                     mentionInk: (ChannelAgent?) -> Color) -> AttributedString {
    var result = parsedTranscriptInlineMarkdown(text)
    for run in result.runs {
        if run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(size: codeSize * textScale, design: .monospaced)
            result[run.range].backgroundColor = .primary.opacity(0.06)
        }
    }
    let plain = String(result.characters)
    guard plain.contains("@") else { return result }
    let handles = Set(["everyone"] + agents.map { agentHandleFromName($0.name) })
    for match in plain.matches(of: inlineMentionPattern) where handles.contains(match.1.lowercased()) {
        let start = plain.index(before: match.1.startIndex)
        guard let lower = AttributedString.Index(start, within: result),
              let upper = AttributedString.Index(match.1.endIndex, within: result),
              result[lower..<upper].runs.allSatisfy({
                  $0.inlinePresentationIntent?.contains(.code) != true && $0.link == nil
              }) else { continue }
        let agent = agents.first { agentHandleFromName($0.name) == match.1.lowercased() }
        let ink = mentionInk(agent)
        for run in result[lower..<upper].runs {
            let intent = run.inlinePresentationIntent ?? []
            let font = Font.system(size: fontSize * textScale,
                                   weight: intent.contains(.stronglyEmphasized) ? .bold : .semibold)
            result[run.range].font = intent.contains(.emphasized) ? font.italic() : font
            result[run.range].foregroundColor = ink
        }
    }
    return result
}

private func parsedTranscriptInlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

public typealias MarkdownBlock = ChannelKit.MarkdownBlock
