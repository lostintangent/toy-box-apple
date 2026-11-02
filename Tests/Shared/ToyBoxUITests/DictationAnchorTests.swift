import Foundation
import Testing
@testable import ToyBoxUI

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
}
