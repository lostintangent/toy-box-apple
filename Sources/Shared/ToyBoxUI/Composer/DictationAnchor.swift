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

    /// The text that dictated words replace, which shows until words arrive.
    public var replacedText: String { (base as NSString).substring(with: replaced) }

    /// What the composer shows for `transcript`, and the caret within it. Padded finalized words
    /// take `attributes` and tentative ones `tentative`, with the caret after the words. Before words
    /// arrive, it shows the replaced text, selected.
    package func display(_ transcript: DictationTranscript, attributes: [NSAttributedString.Key: Any],
                         tentative: [NSAttributedString.Key: Any]) -> (text: NSAttributedString, caret: NSRange) {
        let visible = transcript.visible
        guard !visible.isEmpty else {
            return (NSAttributedString(string: replacedText, attributes: attributes),
                    NSRange(location: 0, length: replacedText.utf16.count))
        }
        let (leading, trailing) = padding(for: visible)
        let text = NSMutableAttributedString(string: leading + transcript.finalized, attributes: attributes)
        text.append(NSAttributedString(string: String(visible.dropFirst(transcript.finalized.count)) + trailing,
                                       attributes: tentative))
        return (text, NSRange(location: text.length - trailing.utf16.count, length: 0))
    }

    /// The draft with `finalized` in place of the anchored range. Without words, the draft is unchanged.
    public func draft(with finalized: String) -> String {
        guard !finalized.isEmpty else { return base }
        let (leading, trailing) = padding(for: finalized)
        return (base as NSString).replacingCharacters(in: replaced, with: leading + finalized + trailing)
    }

    /// Where a selection lands once the shown span `old` becomes `new`: at `caret` from inside the
    /// span, moved with the text after it, or unchanged before it.
    public static func selection(_ selection: NSRange, replacing old: NSRange, with new: NSRange,
                                 caret: NSRange) -> NSRange {
        if selection.location >= old.location, NSMaxRange(selection) <= NSMaxRange(old) { return caret }
        guard selection.location >= NSMaxRange(old) else { return selection }
        return NSRange(location: selection.location + new.length - old.length, length: selection.length)
    }
}
