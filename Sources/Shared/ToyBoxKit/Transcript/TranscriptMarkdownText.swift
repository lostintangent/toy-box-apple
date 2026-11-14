import Foundation

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
                append(MarkdownBlock.parsedInlineMarkdown(value), fragment: .init(block: block.id))
            case .listItem(let marker, let value, _):
                append(AttributedString(marker), fragment: .init(block: block.id))
                text += " "
                append(MarkdownBlock.parsedInlineMarkdown(value), fragment: .init(block: block.id, column: 1))
            case .code(_, let code):
                append(AttributedString(code), fragment: .init(block: block.id))
            case .table(let rows):
                for (row, cells) in rows.enumerated() {
                    if row > 0 { text += "\n" }
                    for (column, cell) in cells.enumerated() {
                        if column > 0 { text += "  " }
                        append(MarkdownBlock.parsedInlineMarkdown(cell),
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
