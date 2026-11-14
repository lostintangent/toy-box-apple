import Foundation
import Testing
@testable import ChannelClient

@Suite("Dictation anchor")
struct DictationAnchorTests {
    @Test("splices finalized words into the draft with padding from the surrounding characters")
    func splicesDictatedWordsWithNeighborPadding() {
        func draft(_ base: String, _ replaced: NSRange, _ finalized: String) -> String {
            DictationAnchor(base: base, replaced: replaced).draft(with: finalized)
        }

        #expect(draft("hello world", NSRange(location: 5, length: 0), "there") == "hello there world")
        #expect(draft("ab", NSRange(location: 1, length: 0), "cd") == "a cd b")
        #expect(draft("ab", NSRange(location: 1, length: 0), "") == "ab")
        #expect(draft("hi", NSRange(location: 0, length: 0), "yo") == "yo hi")
        #expect(draft("hi", NSRange(location: 2, length: 0), "yo") == "hi yo")
        #expect(draft("one two three", NSRange(location: 4, length: 3), "2") == "one 2 three")
        #expect(draft("ab", NSRange(location: 1, length: 0), "?") == "a? b")
        #expect(draft("😀x", NSRange(location: 2, length: 0), "hi") == "😀 hi x")
    }

    @Test("puts a selection inside the shown words at the caret and moves one after them")
    func selectionFollowsTheShownWords() {
        func selection(_ location: Int, _ length: Int = 0) -> NSRange {
            DictationAnchor.selection(NSRange(location: location, length: length),
                                      replacing: NSRange(location: 4, length: 2), with: NSRange(location: 4, length: 7),
                                      caret: NSRange(location: 11, length: 0))
        }

        #expect(selection(2, 2) == NSRange(location: 2, length: 2))
        #expect(selection(4, 2) == NSRange(location: 11, length: 0))
        #expect(selection(8, 1) == NSRange(location: 13, length: 1))
    }
}
