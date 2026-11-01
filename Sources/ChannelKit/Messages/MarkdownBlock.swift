import Foundation

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

    public static func parse(_ source: String) -> [MarkdownBlock] {
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
