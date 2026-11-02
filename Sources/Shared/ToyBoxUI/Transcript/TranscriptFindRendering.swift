import Foundation
import SwiftUI

public struct TranscriptFindPattern {
    public let query: String

    public init(_ query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func ranges(in text: String) -> [Range<Int>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<Int>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: start..<text.endIndex, locale: Locale(identifier: "en_US_POSIX")) {
            guard !range.isEmpty else {
                start = text.index(after: start)
                continue
            }
            let utf16 = NSRange(range, in: text)
            result.append(utf16.location..<(utf16.location + utf16.length))
            start = range.upperBound
        }
        return result
    }
}

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
