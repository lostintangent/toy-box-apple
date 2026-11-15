import Foundation

/// When the conversation counts as read, on both apps: through its newest message whenever the
/// reader is looking at it, as the web does, wherever they've scrolled. Arrivals are read as they
/// come. ChannelStore skips what the server already has and joins overlapping writes.
public struct TranscriptRead: Equatable, Sendable {
    public var latestSequence: Int?
    /// The Mac's key window, or the phone's active scene showing this channel.
    public var isLooking: Bool
    /// A viewer, management flow or sheet on top of the conversation.
    public var isCovered: Bool
    /// Landing captures New before anything is read.
    public var hasLanded: Bool
    public var isConnected: Bool

    public init(latestSequence: Int?, isLooking: Bool, isCovered: Bool, hasLanded: Bool, isConnected: Bool) {
        self.latestSequence = latestSequence
        self.isLooking = isLooking
        self.isCovered = isCovered
        self.hasLanded = hasLanded
        self.isConnected = isConnected
    }

    /// The sequence to mark read, or nil while the reader isn't looking.
    public var sequence: Int? {
        guard isLooking, !isCovered, hasLanded, isConnected else { return nil }
        return latestSequence
    }
}
