import SwiftUI

/// A title with its disclosure trailing inline, as macOS sidebar section headers do: the title,
/// an optional count such as "3/4", then the chevron, as one wrapping text. Non-breaking spaces
/// carry the chevron with the title's last word, so it never wraps onto a line of its own.
enum OverviewInlineDisclosure {
    static func line(_ title: Text, isExpanded: Bool, count: String? = nil, showsChevron: Bool = true,
                     textScale: CGFloat) -> Text {
        let gap = Text(verbatim: "\u{00A0}\u{00A0}").font(.system(size: 13 * textScale))
        let chevron = Text(Image(systemName: isExpanded ? "chevron.down" : "chevron.right"))
            .font(.system(size: 9 * textScale, weight: .bold))
            .foregroundStyle(.secondary)
        guard let count else { return showsChevron ? title + gap + chevron : title }
        let counted = Text(verbatim: showsChevron ? "\(count)\u{00A0}" : count)
            .font(.system(size: 11 * textScale).monospacedDigit())
            .foregroundStyle(.secondary)
        guard showsChevron else { return title + gap + counted }
        return title + gap + counted + chevron
    }
}
