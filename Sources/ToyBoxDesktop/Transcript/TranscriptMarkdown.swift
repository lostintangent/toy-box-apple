import AppKit
import ChannelKit
import SwiftUI
import ToyBoxUI

struct TranscriptMarkdown: View {
    let content: String
    var agents: [ChannelAgent] = []
    var baseURL: URL?
    /// Each selectable `Text` mounts its own platform text view, which is most of what a long
    /// message costs to scroll into view, so transcript rows turn this on when the pointer first
    /// reaches them.
    var selectable = true
    var findHighlight: TranscriptFindHighlight?
    var bodySize: CGFloat = 14
    var codeSize: CGFloat = 12
    var lineSpacing: CGFloat = 3
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.transcriptSurface) private var surface

    var body: some View {
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
                     ?? AttributedString(marker)).foregroundStyle(.secondary).textSelection(.disabled)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(inline(text, fragment: .init(block: block.id, column: 1), highlights: highlights))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                Text(inline(text, fragment: .init(block: block.id), highlights: highlights)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(language.isEmpty ? "Code" : language).foregroundStyle(.secondary)
                        .textSelection(.disabled)
                    Spacer(minLength: 12)
                    Button("Copy Code", systemImage: "doc.on.doc") {
                        TranscriptClipboard.copy(code)
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
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(0..<(rows.map(\.count).max() ?? 0), id: \.self) { column in
                                Text(inline(column < rows[row].count ? rows[row][column] : "", size: 13,
                                            fragment: .init(block: block.id, row: row, column: column),
                                            highlights: highlights))
                                    .font(.system(size: 13 * textScale,
                                                  weight: row == 0 ? .semibold : .regular))
                                    .frame(minWidth: 64, maxWidth: 280, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .frame(maxHeight: .infinity, alignment: .topLeading)
                                    .background(row == 0 ? Color.primary.opacity(0.05) : .clear)
                                    .overlay(alignment: .bottom) { Divider() }
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
            }
        case .rule:
            Divider().padding(.vertical, 4)
        }
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
                                              mentions: .init(surface: surface, isDark: colorScheme == .dark,
                                                              isContrastIncreased: contrast == .increased))
        return highlights?.applying(to: result, fragment: fragment) ?? result
    }
}

/// One rendered stream with offsets into each independently laid-out Text, including table cells.
struct TranscriptMarkdownText {
    struct Fragment: Hashable {
        var block: Int
        var row = 0
        var column = 0
    }

    private(set) var text = ""
    private(set) var offsets: [Fragment: Int] = [:]

    init(_ blocks: [MarkdownBlock]) {
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

struct TranscriptMarkdownHighlights {
    let highlight: TranscriptFindHighlight
    let document: TranscriptMarkdownText
    let ranges: [Range<Int>]

    init(blocks: [MarkdownBlock], highlight: TranscriptFindHighlight) {
        self.highlight = highlight
        document = TranscriptMarkdownText(blocks)
        ranges = TranscriptFindPattern(highlight.query).ranges(in: document.text)
    }

    func applying(to value: AttributedString, fragment: TranscriptMarkdownText.Fragment) -> AttributedString {
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
            .foregroundStyle(configuration.isPressed ? .primary : .secondary)
            .contentShape(Rectangle())
    }
}

/// The surface a block of transcript text sits on. Rows draw their bubbles from these fills, and
/// mention ink is clamped against the same composite, so the two can't drift apart.
enum TranscriptSurface: Hashable, Sendable {
    case canvas, agent, pendingAgent, user

    /// Fills layered over the transcript canvas, bottom first.
    func fills(isDark: Bool) -> [Color] {
        let neutral = Color.primary.opacity(isDark ? 0.07 : 0.045)
        switch self {
        case .canvas: return []
        case .agent: return [neutral]
        // In dark, the wash sits over the neutral fill so it reads warm gray rather than brown.
        case .pendingAgent: return isDark ? [neutral, .orange.opacity(0.10)] : [.orange.opacity(0.10)]
        case .user: return [.accentColor.opacity(0.09)]
        }
    }

    /// The 1-point edge Increase Contrast adds, so every bubble keeps a boundary however close its
    /// fill sits to the canvas. A pending request keeps its orange.
    var increasedContrastEdge: Color? {
        switch self {
        case .canvas: nil
        case .agent, .user: .primary.opacity(0.5)
        case .pendingAgent: .orange
        }
    }
}

extension View {
    /// Draws a message bubble for `surface` behind the content: its fills and, under Increase
    /// Contrast, its edge.
    func transcriptBubble(_ surface: TranscriptSurface) -> some View {
        modifier(TranscriptBubble(surface: surface))
    }
}

private struct TranscriptBubble: ViewModifier {
    let surface: TranscriptSurface
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        content
            .background {
                ZStack {
                    ForEach(Array(surface.fills(isDark: colorScheme == .dark).enumerated()), id: \.offset) {
                        shape.fill($0.element)
                    }
                }
            }
            .overlay {
                if contrast == .increased, let edge = surface.increasedContrastEdge {
                    shape.strokeBorder(edge, lineWidth: 1)
                }
            }
    }
}

private struct TranscriptSurfaceKey: EnvironmentKey {
    static let defaultValue = TranscriptSurface.canvas
}

extension EnvironmentValues {
    var transcriptSurface: TranscriptSurface {
        get { self[TranscriptSurfaceKey.self] }
        set { self[TranscriptSurfaceKey.self] = newValue }
    }
}

/// Mentions take their agent's identity color, mixed toward black in light appearance or white in
/// dark in 5% steps until they reach text contrast with the surface beneath them.
struct TranscriptMentionInk: Equatable {
    var surface = TranscriptSurface.canvas
    var isDark = false
    var isContrastIncreased = false

    var minimumContrast: Double { isContrastIncreased ? 7 : 4.5 }

    func color(for agent: ChannelAgent?) -> Color {
        let identity = agent?.avatar.flatMap { Color(hex: $0.color) } ?? .accentColor
        let name: NSAppearance.Name = switch (isDark, isContrastIncreased) {
        case (false, false): .aqua
        case (true, false): .darkAqua
        case (false, true): .accessibilityHighContrastAqua
        case (true, true): .accessibilityHighContrastDarkAqua
        }
        var ink = Color.primary
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            guard let base = TranscriptRGB(identity) else { return }
            // Popovers that reuse transcript Markdown sit on the window background instead.
            let canvases = (surface == .canvas ? [NSColor.textBackgroundColor, .windowBackgroundColor]
                                               : [NSColor.textBackgroundColor]).compactMap(TranscriptRGB.init)
            let backgrounds = canvases.map { canvas in
                surface.fills(isDark: isDark).reduce(canvas) { below, fill in
                    TranscriptRGB(fill).map { below.under($0) } ?? below
                }
            }
            let target = isDark ? TranscriptRGB(red: 1, green: 1, blue: 1) : TranscriptRGB(red: 0, green: 0, blue: 0)
            for step in 0...20 {
                let candidate = base.mixed(toward: target, by: Double(step) / 20)
                if step == 20 || backgrounds.allSatisfy({ candidate.contrast(with: $0) >= minimumContrast }) {
                    ink = Color(.sRGB, red: candidate.red, green: candidate.green, blue: candidate.blue)
                    return
                }
            }
        }
        return ink
    }
}

/// An opaque sRGB color for contrast arithmetic.
struct TranscriptRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }

    /// Resolves in the current drawing appearance.
    init?(_ color: Color) { self.init(NSColor(color)) }

    init?(_ color: NSColor) {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
                  alpha: color.alphaComponent)
    }

    /// This color with `layer` composited over it.
    func under(_ layer: TranscriptRGB) -> TranscriptRGB {
        TranscriptRGB(red: layer.red * layer.alpha + red * (1 - layer.alpha),
                      green: layer.green * layer.alpha + green * (1 - layer.alpha),
                      blue: layer.blue * layer.alpha + blue * (1 - layer.alpha))
    }

    func mixed(toward target: TranscriptRGB, by amount: Double) -> TranscriptRGB {
        TranscriptRGB(red: red + (target.red - red) * amount, green: green + (target.green - green) * amount,
                      blue: blue + (target.blue - blue) * amount)
    }

    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(with other: TranscriptRGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

// Hoisted so rendering a row doesn't compile its patterns again for every line or message.
nonisolated(unsafe) private let inlineMentionPattern = /(?:^|[^a-zA-Z0-9-])@([a-zA-Z0-9][a-zA-Z0-9-]*)/
nonisolated(unsafe) private let headingPattern = /^(#{1,6})\s+(.+?)\s*#*\s*$/
nonisolated(unsafe) private let listItemPattern = /^(\s*)([-+*]|\d+[.)])\s+(.+)$/
private let setextUnderlinePattern = try! NSRegularExpression(pattern: #"^(?:=+|-+)\s*$"#)
private let thematicBreakPattern = try! NSRegularExpression(
    pattern: #"^(?:\*\s*){3,}$|^(?:-\s*){3,}$|^(?:_\s*){3,}$"#)
private let tableRuleCellPattern = try! NSRegularExpression(pattern: #"^:?-{3,}:?$"#)

private extension NSRegularExpression {
    func matches(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

func transcriptInlineMarkdown(_ text: String, agents: [ChannelAgent], textScale: CGFloat = 1,
                              fontSize: CGFloat = 14, codeSize: CGFloat = 12,
                              mentions: TranscriptMentionInk = .init()) -> AttributedString {
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
        let ink = mentions.color(for: agent)
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

struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph(String)
        case heading(Int, String)
        case listItem(String, String, Int)
        case quote(String)
        case code(String, String)
        case table([[String]])
        case rule
    }

    var id: Int
    var kind: Kind

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        func append(_ kind: Kind) { blocks.append(.init(id: blocks.count, kind: kind)) }
        func flush() {
            if !paragraph.isEmpty {
                append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let marker = trimmed.first!
                let fenceLength = trimmed.prefix(while: { $0 == marker }).count
                let language = String(trimmed.dropFirst(fenceLength)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count && !closesFence(lines[index], marker: marker, length: fenceLength) {
                    code.append(lines[index])
                    index += 1
                }
                append(.code(language, code.joined(separator: "\n")))
            } else if index + 1 < lines.count, line.contains("|"), isTableRule(lines[index + 1]) {
                flush()
                var rows = [tableCells(line)]
                index += 2
                while index < lines.count && lines[index].contains("|")
                    && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                append(.table(rows))
                continue
            } else if !paragraph.isEmpty, setextUnderlinePattern.matches(trimmed) {
                append(.heading(trimmed.hasPrefix("=") ? 1 : 2, paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            } else if let heading = trimmed.firstMatch(of: headingPattern) {
                flush()
                append(.heading(heading.1.count, String(heading.2)))
            } else if thematicBreakPattern.matches(trimmed) {
                flush()
                append(.rule)
            } else if trimmed.hasPrefix(">") {
                flush()
                var quote = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while index + 1 < lines.count,
                      lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    index += 1
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                }
                append(.quote(quote.joined(separator: "\n")))
            } else if let item = line.firstMatch(of: listItemPattern) {
                flush()
                let marker = String(item.2)
                let body = String(item.3)
                let task = body.hasPrefix("[ ] ") ? ("square", String(body.dropFirst(4)))
                    : body.lowercased().hasPrefix("[x] ") ? ("checkmark", String(body.dropFirst(4))) : nil
                append(.listItem(task.map { $0.0 == "square" ? "\u{2610}" : "\u{2611}" }
                                 ?? (["-", "+", "*"].contains(marker) ? "\u{2022}" : marker),
                                 task?.1 ?? body, item.1.count / 2))
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flush()
        return blocks
    }

    private static func isTableRule(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy { tableRuleCellPattern.matches($0) }

    }

    private static func closesFence(_ line: String, marker: Character, length: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let count = trimmed.prefix(while: { $0 == marker }).count
        return count >= length && trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var inCode = false
        for character in trimmed {
            if character == "|" && !escaped && !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            if character == "`" && !escaped { inCode.toggle() }
            escaped = character == "\\" && !escaped
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

enum TranscriptClipboard {
    static func copy(_ content: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }
}
