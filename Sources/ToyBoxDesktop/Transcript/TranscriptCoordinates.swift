import Foundation

enum TranscriptCoordinates {
    static let contentTopPadding: CGFloat = 20

    // Native clipping can move without another viewport-frame preference.
    static func viewportFrame(_ frame: TranscriptMessageFrame, top: CGFloat) -> TranscriptMessageFrame {
        var positioned = frame
        positioned.rect.origin.y = contentTopPadding + frame.contentTop - top
        return positioned
    }

}
