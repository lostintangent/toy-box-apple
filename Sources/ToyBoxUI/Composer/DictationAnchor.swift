import ChannelClient
import Foundation

/// The draft a dictation session started from: the caret or selection that dictated words replace.
public struct DictationAnchor {
    /// The draft before dictation began.
    public let base: String
    /// The range of `base` that dictated words replace.
    public let replaced: NSRange

    public init(base: String, replaced: NSRange) {
        self.base = base
        self.replaced = replaced
    }

    /// The spaces that separate `words` from the characters on either side of the anchor.
    public func padding(for words: String) -> (leading: String, trailing: String) {
        let text = base as NSString
        let start = replaced.location
        let end = NSMaxRange(replaced)
        let previous = start > 0 ? text.substring(with: text.rangeOfComposedCharacterSequence(at: start - 1)).first : nil
        let next = end < text.length ? text.substring(with: text.rangeOfComposedCharacterSequence(at: end)).first : nil
        return DictationTranscript.padding(for: words, after: previous, before: next)
    }

    /// The draft with `finalized` in place of the anchored range. Without words, the draft is unchanged.
    public func draft(with finalized: String) -> String {
        guard !finalized.isEmpty else { return base }
        let (leading, trailing) = padding(for: finalized)
        return (base as NSString).replacingCharacters(in: replaced, with: leading + finalized + trailing)
    }
}
