import Foundation

/// When the conversation counts as read, on both apps, exactly as the web does: through its newest
/// message whenever it's on screen and connected, wherever it's scrolled and whatever sits on top.
/// Arrivals are read as they come. ChannelStore skips what the server already has and joins
/// overlapping writes.
public struct TranscriptRead: Equatable, Sendable {
    public var latestSequence: Int?
    /// The Mac's key window, or the channel the phone's navigation shows in its active scene.
    public var isLooking: Bool
    public var isConnected: Bool

    public init(latestSequence: Int?, isLooking: Bool, isConnected: Bool) {
        self.latestSequence = latestSequence
        self.isLooking = isLooking
        self.isConnected = isConnected
    }

    /// The sequence to mark read, or nil while the reader isn't looking.
    public var sequence: Int? {
        guard isLooking, isConnected else { return nil }
        return latestSequence
    }
}
