import ToyBoxClient
import SwiftUI

public struct TranscriptFindHighlight: Equatable {
    public let query: String
    public let isCurrent: Bool
    public let background: Color
    public let foreground: Color

    public init(query: String, isCurrent: Bool, background: Color, foreground: Color) {
        self.query = query
        self.isCurrent = isCurrent
        self.background = background
        self.foreground = foreground
    }

    public func applying(to value: AttributedString, ranges: [Range<Int>]? = nil,
                         offset: Int = 0) -> AttributedString {
        let plain = String(value.characters)
        let occurrences = ranges ?? TranscriptFindPattern(query).ranges(in: plain)
        let bounds = offset..<(offset + plain.utf16.count)
        var result = value
        for occurrence in occurrences {
            let lower = max(bounds.lowerBound, occurrence.lowerBound)
            let upper = min(bounds.upperBound, occurrence.upperBound)
            guard lower < upper,
                  let range = Range(NSRange(location: lower - offset, length: upper - lower), in: plain),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[start..<end].backgroundColor = background.opacity(isCurrent ? 1 : 0.45)
            result[start..<end].foregroundColor = foreground
        }
        return result
    }
}

extension TranscriptFind {
    /// Every match while Find is open, by sequence, with the current one emphasized.
    public func highlights(_ make: (_ query: String, _ isCurrent: Bool) -> TranscriptFindHighlight)
        -> [Int: TranscriptFindHighlight] {
        guard isPresented else { return [:] }
        return Dictionary(uniqueKeysWithValues: matches.map { ($0.sequence, make(query, $0.sequence == selectedSequence)) })
    }
}
