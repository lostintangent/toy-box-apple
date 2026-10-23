import SwiftUI

extension View {
    /// Lays this column's content out only at sizes its window can show. See `SettledLayout`.
    func settledLayout() -> some View {
        SettledLayout { self }
    }
}

/// Keeps a column's content at the last size its window showed through AppKit's temporary sizing
/// passes.
///
/// Each frame of a window resize, the split views size their columns in temporary layout passes
/// that propose sizes no window shows, such as a conversation 52 points tall, an Overview with no
/// width or an infinite sidebar. SwiftUI laid each column out again at every one of them, so the
/// transcript rewrapped its visible messages at three widths per frame and a frame took about
/// 190 ms. This layout answers those proposals without measuring its content and leaves the content
/// where it was, so the content lays out once per frame, at the size the window shows. The column's
/// own size still comes from its frame and column width modifiers, which sit outside this layout.
struct SettledLayout: Layout {
    /// Every column in a window at its 760 x 560 floor is at least this big, and the temporary
    /// passes propose less in at least one dimension.
    static let minimumShownSize = CGSize(width: 100, height: 200)

    static func isShown(_ proposal: ProposedViewSize) -> Bool {
        guard let width = proposal.width, let height = proposal.height else { return false }
        return width.isFinite && height.isFinite
            && width >= minimumShownSize.width && height >= minimumShownSize.height
    }

    func makeCache(subviews: Subviews) -> CGSize? { nil }

    /// The settled size outlives content changes. Only the next shown size replaces it.
    func updateCache(_ cache: inout CGSize?, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CGSize?) -> CGSize {
        if !Self.isShown(proposal), let settled = cache {
            return CGSize(width: proposal.width ?? settled.width, height: proposal.height ?? settled.height)
        }
        return subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout CGSize?) {
        var size = bounds.size
        if Self.isShown(ProposedViewSize(size)) {
            cache = size
        } else if let settled = cache {
            size = settled
        }
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(size))
    }
}
