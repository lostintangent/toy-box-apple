import Foundation

public enum TranscriptCoordinates {
    public static let contentTopPadding: CGFloat = 20

    // Native clipping can move without another viewport-frame preference.
    public static func viewportFrame(_ frame: TranscriptMessageFrame, top: CGFloat) -> TranscriptMessageFrame {
        var positioned = frame
        positioned.rect.origin.y = contentTopPadding + frame.contentTop - top
        return positioned
    }

    // Viewport frames can lag native scrolling, so replaying one must set the same absolute offset.
    public static func targetOffset(for frame: TranscriptMessageFrame, bottom: CGFloat, topInset: CGFloat) -> CGFloat {
        contentTopPadding + frame.contentTop + frame.rect.height - bottom - topInset
    }

    public static func isRestored(_ frame: TranscriptMessageFrame, bottom: CGFloat, nativeIsAligned: Bool) -> Bool {
        nativeIsAligned && abs(frame.rect.maxY - bottom) <= 0.5
    }
}
