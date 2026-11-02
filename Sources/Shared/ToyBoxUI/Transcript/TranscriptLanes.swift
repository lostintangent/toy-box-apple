import SwiftUI

/// Wraps content at a readable line without stretching it there, so a surface still hugs a short
/// message and a wider lane adds air rather than longer lines.
public struct TranscriptWidthCap: Layout {
    /// About 115 characters of body text at the Mac's default Text Size.
    public static let agentSurface: CGFloat = 760
    public var maxWidth: CGFloat

    public init(maxWidth: CGFloat) { self.maxWidth = maxWidth }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: capped(proposal))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
    }
}

extension View {
    public func transcriptWidthCap(_ maxWidth: CGFloat) -> some View {
        TranscriptWidthCap(maxWidth: maxWidth) { self }
    }
}

/// Pins your messages to the trailing edge, hugging them up to `fraction` of the lane or `maxWidth`.
public struct TranscriptUserLane: Layout {
    public static let maximumWidth: CGFloat = 640
    public var maxWidth: CGFloat
    public var fraction: CGFloat

    public init(maxWidth: CGFloat, fraction: CGFloat = 0.8) {
        self.maxWidth = maxWidth
        self.fraction = fraction
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let size = subviews.first?.sizeThatFits(contentProposal(width)) ?? .zero
        return CGSize(width: width, height: size.height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let proposal = contentProposal(bounds.width)
        let size = content.sizeThatFits(proposal)
        content.place(at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY), proposal: proposal)
    }

    private func contentProposal(_ width: CGFloat) -> ProposedViewSize {
        ProposedViewSize(width: min(width * fraction, maxWidth), height: nil)
    }
}
