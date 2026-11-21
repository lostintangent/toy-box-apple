import Foundation

/// The words of one dictation session: what the transcriber has finalized, then its current guess.
package struct DictationTranscript: Equatable {
    package private(set) var finalized = ""
    package private(set) var tentative = ""

    package init() {}

    package var isEmpty: Bool { visible.isEmpty }
    /// Everything the composer shows. `finalized` is always its prefix.
    package var visible: String { Self.join(finalized, tentative) }

    /// Returns whether the shown words changed.
    @discardableResult
    package mutating func receive(_ text: String, isFinal: Bool) -> Bool {
        let old = self
        if isFinal {
            finalized = Self.join(finalized, text)
            tentative = ""
        } else {
            tentative = text
        }
        return visible != old.visible || finalized != old.finalized
    }

    /// Keeps every word the person has seen, for stops that can't wait for the transcriber.
    package mutating func promoteTentative() {
        finalized = visible
        tentative = ""
    }

    package mutating func discardTentative() { tentative = "" }

    /// Joins transcriber segments, which carry their own leading spaces, such as "facing", "?" and " and check".
    package static func join(_ head: String, _ tail: String) -> String {
        guard !head.isEmpty else { return String(tail.drop(while: \.isWhitespace)) }
        guard let last = head.last, let first = tail.first else { return head }
        if !last.isWhitespace, first.isLetter || first.isNumber { return head + " " + tail }
        return head + tail
    }
}
