import ChannelKit
import Testing

@Suite("Message Markdown blocks")
struct MarkdownBlockTests {
    @Test func paragraphsKeepSelectableInlineMarkdownAndLineBreaks() {
        #expect(MarkdownBlock.parse("").isEmpty)
        #expect(MarkdownBlock.parse(" \n\n ").isEmpty)
        let blocks = MarkdownBlock.parse("Hello **team** and @lead.\nA second line.\n\nNext paragraph.")
        #expect(blocks.map(\.kind) == [
            .paragraph("Hello **team** and @lead.\nA second line."),
            .paragraph("Next paragraph.")
        ])
        #expect(blocks.map(\.id) == [0, 1])
    }

    @Test func headingsQuotesAndListsHaveDistinctBlocks() {
        let source = """
        # Direction
        > A quote
        > continued.

        - One
          - Nested
        2. Two
        - [x] Done
        - [ ] Pending
        """
        #expect(MarkdownBlock.parse(source).map(\.kind) == [
            .heading(1, "Direction"), .quote("A quote\ncontinued."),
            .listItem("\u{2022}", "One", 0), .listItem("\u{2022}", "Nested", 1),
            .listItem("2.", "Two", 0), .listItem("\u{2611}", "Done", 0),
            .listItem("\u{2610}", "Pending", 0)
        ])
        #expect(MarkdownBlock.parse("Title\n=====\n\nSubtitle\n---\n\n---").map(\.kind) == [
            .heading(1, "Title"), .heading(2, "Subtitle"), .rule
        ])
    }

    @Test func setextUnderlinesKeepTheirWhitespaceAndMarkerBoundaries() {
        let cases: [(String, [MarkdownBlock.Kind])] = [
            ("Title\n== \r", [.heading(1, "Title")]),
            ("Title\n--\r", [.heading(2, "Title")]),
            ("Title\n=\u{2028}", [.heading(1, "Title")]),
            ("Title\n-\t-\t-", [.paragraph("Title"), .rule]),
            ("Title\n== =", [.paragraph("Title\n== =")]),
        ]
        for (source, expected) in cases {
            #expect(MarkdownBlock.parse(source).map(\.kind) == expected, "\(source.debugDescription)")
        }
    }

    @Test func thematicBreaksRequireThreeMatchingMarkersWithWhitespaceBetween() {
        let cases: [(String, [MarkdownBlock.Kind])] = [
            ("---\r", [.rule]),
            ("-\t-\t-", [.rule]),
            ("-\u{00a0}-\u{00a0}-", [.rule]),
            ("** *", [.rule]),
            ("___", [.rule]),
            ("---\u{00a0}", [.rule]),
            ("__", [.paragraph("__")]),
            ("--", [.paragraph("--")]),
            ("-*-", [.paragraph("-*-")]),
        ]
        for (source, expected) in cases {
            #expect(MarkdownBlock.parse(source).map(\.kind) == expected, "\(source.debugDescription)")
        }
    }

    @Test func tableRuleCellsAcceptOneOptionalAlignmentColonAtEachEnd() {
        let cases: [(String, [MarkdownBlock.Kind])] = [
            ("| H | V |\n| :--- | ---: |\n| x | y |", [.table([["H", "V"], ["x", "y"]])]),
            ("| H |\n| :---: |", [.table([["H"]])]),
            ("| H |\n| --- |", [.table([["H"]])]),
            ("| H |\n| ::--- |", [.paragraph("| H |\n| ::--- |")]),
            ("| H |\n| ---:: |", [.paragraph("| H |\n| ---:: |")]),
            ("| H |\n| -- |", [.paragraph("| H |\n| -- |")]),
            ("| H |\n| --\u{00a0}- |", [.paragraph("| H |\n| --\u{00a0}- |")]),
        ]
        for (source, expected) in cases {
            #expect(MarkdownBlock.parse(source).map(\.kind) == expected, "\(source.debugDescription)")
        }
    }

    @Test func wrappedListItemsKeepTheirMarkerAndSeparateAfterABlankLine() {
        let source = """
        - Put a request where
          the reader can find it.
          **Keep this** part too.
          - Nested item with
            its own continuation.
        2. Numbered item with
           more text.
        - [x] Checked task with
          a trailing note.

        A separate paragraph,
        still its own block.
        """
        let blocks = MarkdownBlock.parse(source)
        #expect(blocks.map(\.kind) == [
            .listItem("\u{2022}", "Put a request where\nthe reader can find it.\n**Keep this** part too.", 0),
            .listItem("\u{2022}", "Nested item with\nits own continuation.", 1),
            .listItem("2.", "Numbered item with\nmore text.", 0),
            .listItem("\u{2611}", "Checked task with\na trailing note.", 0),
            .paragraph("A separate paragraph,\nstill its own block.")
        ])
        #expect(blocks.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test func wrappedListItemsStopBeforeOtherBlockKinds() {
        let source = """
        - First item
        # Heading
        - Second item
        > Quote
        - Third item
        ```text
        code
        ```
        - Fourth item
        ---
        - Fifth item
        | Head | Value |
        | --- | --- |
        | Cell | Text |
        - Sixth item
        """
        #expect(MarkdownBlock.parse(source).map(\.kind) == [
            .listItem("\u{2022}", "First item", 0), .heading(1, "Heading"),
            .listItem("\u{2022}", "Second item", 0), .quote("Quote"),
            .listItem("\u{2022}", "Third item", 0), .code("text", "code"),
            .listItem("\u{2022}", "Fourth item", 0), .rule,
            .listItem("\u{2022}", "Fifth item", 0),
            .table([["Head", "Value"], ["Cell", "Text"]]),
            .listItem("\u{2022}", "Sixth item", 0)
        ])
    }

    @Test func fencedCodeStaysLiteralUntilAMatchingClosingFence() {
        #expect(MarkdownBlock.parse("```swift\nlet x = \"@lead | **not bold**\"\n```\nAfter").map(\.kind) == [
            .code("swift", "let x = \"@lead | **not bold**\""), .paragraph("After")
        ])
        let source = "````markdown\n```swift\nlet x = 1\n```\n````\nAfter"
        #expect(MarkdownBlock.parse(source).map(\.kind) == [
            .code("markdown", "```swift\nlet x = 1\n```"), .paragraph("After")
        ])
        #expect(MarkdownBlock.parse("~~~text\nOne\nTwo").map(\.kind) == [.code("text", "One\nTwo")])
        #expect(MarkdownBlock.parse("```\n```not a closing fence\nend\n```").map(\.kind) == [
            .code("", "```not a closing fence\nend")
        ])
    }

    @Test func tablesKeepEscapedPipesAndInlineCodeTogether() {
        let source = """
        | Name | Value |
        | :--- | ---: |
        | left\\|right | `a|b` |
        | trailing | value |
        """
        #expect(MarkdownBlock.parse(source).map(\.kind) == [
            .table([["Name", "Value"], ["left\\|right", "`a|b`"], ["trailing", "value"]])
        ])
        #expect(MarkdownBlock.parse("one | two\nnot a table").map(\.kind) == [
            .paragraph("one | two\nnot a table")
        ])
    }

    @Test func htmlRemainsInertText() {
        let html = "<script>alert('never execute')</script>"
        #expect(MarkdownBlock.parse(html).map(\.kind) == [.paragraph(html)])
    }

    @Test func findTextKeepsNumberedAndTaskMarkersWithoutNotificationTrimming() {
        let blocks = MarkdownBlock.parse("1. [x] **Done**\n  - Nested [note](https://example.test)")
        let projection = TranscriptMarkdownText(blocks)
        #expect(projection.text == "\u{2611} Done\n\u{2022} Nested note")
        #expect(projection.offsets[.init(block: 0)] == 0)
        #expect(projection.offsets[.init(block: 0, column: 1)] == 2)
        #expect(projection.offsets[.init(block: 1, column: 1)] == 9)
    }
}
