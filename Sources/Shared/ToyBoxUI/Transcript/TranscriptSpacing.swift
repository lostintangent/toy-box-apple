import ToyBoxKit
import CoreGraphics

/// The vertical rhythm both apps' transcripts share.
public enum TranscriptSpacing {
    /// Above a row: another sender, a user message or a system group.
    public static let run: CGFloat = 20
    /// Between messages in one agent's run.
    public static let entry: CGFloat = 8
    /// Between system groups that follow each other with no divider between them.
    public static let stackedSystem: CGFloat = 4
    /// Above a divider's line and below it, before the row it introduces.
    public static let divider: CGFloat = 16

    /// The gap above a row that may open with a divider.
    public static func above(_ divider: TranscriptDivider?) -> CGFloat {
        divider == nil ? run : self.divider
    }

    /// The gap above `row` when it follows `previous`.
    public static func between(_ previous: TranscriptRow, _ row: TranscriptRow) -> CGFloat {
        if row.divider == nil, case .system = previous.content, case .system = row.content { return stackedSystem }
        return above(row.divider)
    }
}
