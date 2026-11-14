import Foundation

nonisolated(unsafe) private let headingPattern = /^(#{1,6})\s+(.+?)\s*#*\s*$/
nonisolated(unsafe) private let listItemPattern = /^(\s*)([-+*]|\d+[.)])\s+(.+)$/

public struct MarkdownBlock: Identifiable, Equatable {
    public enum Kind: Equatable {
        case paragraph(String)
        case heading(Int, String)
        case listItem(String, String, Int)
        case quote(String)
        case code(String, String)
        case table([[String]])
        case rule
    }

    public var id: Int
    public var kind: Kind

    public init(id: Int, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// Links become their text, code keeps its contents, list items keep a bullet and each block
    /// takes one line.
    public static func plainText(_ markdown: String) -> String {
        func unformatted(_ text: String) -> String { String(parsedInlineMarkdown(text).characters) }
        return parse(markdown).compactMap { block -> String? in
            switch block.kind {
            case .paragraph(let text), .heading(_, let text), .quote(let text): unformatted(text)
            case .listItem(_, let text, _): "\u{2022} " + unformatted(text)
            case .code(_, let code): code
            case .table(let rows): rows.map { $0.map(unformatted).joined(separator: "  ") }.joined(separator: "\n")
            case .rule: nil
            }
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    /// Keep the same inline whitespace in plain-text projections, Find offsets and rendered text.
    public static func parsedInlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        var afterBlankLine = false
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
            let separatedByBlankLine = afterBlankLine
            afterBlankLine = trimmed.isEmpty
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
            } else if !paragraph.isEmpty, let level = setextLevel(trimmed) {
                append(.heading(level, paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            } else if let heading = trimmed.firstMatch(of: headingPattern) {
                flush()
                append(.heading(heading.1.count, String(heading.2)))
            } else if isThematicBreak(trimmed) {
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
                let taskMarker: String? = body.hasPrefix("[ ] ") ? "\u{2610}"
                    : body.lowercased().hasPrefix("[x] ") ? "\u{2611}" : nil
                append(.listItem(taskMarker ?? (["-", "+", "*"].contains(marker) ? "\u{2022}" : marker),
                                 taskMarker == nil ? body : String(body.dropFirst(4)), item.1.count / 2))
            } else if !separatedByBlankLine, paragraph.isEmpty, let last = blocks.indices.last,
                      case .listItem(let marker, let text, let depth) = blocks[last].kind {
                let continuation = line.drop(while: { $0 == " " || $0 == "\t" })
                blocks[last].kind = .listItem(marker, text + "\n" + String(continuation), depth)
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flush()
        return blocks
    }

    private static func setextLevel(_ line: String) -> Int? {
        guard let marker = line.first, marker == "=" || marker == "-",
              line.drop(while: { $0 == marker }).allSatisfy(\.isWhitespace) else { return nil }
        return marker == "=" ? 1 : 2
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        guard let marker = line.first, marker == "*" || marker == "-" || marker == "_" else { return false }
        var count = 0
        for character in line {
            if character == marker { count += 1 }
            else if !character.isWhitespace { return false }
        }
        return count >= 3
    }

    private static func isTableRule(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy(isTableRuleCell)
    }

    private static func isTableRuleCell(_ cell: String) -> Bool {
        var markers = cell[...]
        if markers.first == ":" { markers.removeFirst() }
        if markers.last == ":" { markers.removeLast() }
        return markers.count >= 3 && markers.allSatisfy { $0 == "-" }
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
