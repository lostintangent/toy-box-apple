import Foundation

/// What the visible conversation has read, on both apps. Each app reports its own facts, and a read
/// counts once they've held still for `stillness`. ChannelStore skips what the server already has.
public struct TranscriptRead: Equatable, Sendable {
    /// The newest message the reader can see, by `TranscriptPlacement.visibleRows`.
    public var visibleThrough: Int?
    /// The Mac's key window, or the phone's active scene showing this channel.
    public var isLooking: Bool
    /// A viewer, management flow or sheet on top of the conversation.
    public var isCovered: Bool
    public var hasLanded: Bool
    /// A reveal, a paging restore or the reader's own scroll.
    public var isMoving: Bool
    /// Find holds the reading position, as `TranscriptFind.blocksRead` says.
    public var isFinding: Bool
    public var isConnected: Bool

    public static let stillness: TimeInterval = 0.25

    public init(visibleThrough: Int?, isLooking: Bool, isCovered: Bool, hasLanded: Bool, isMoving: Bool,
                isFinding: Bool, isConnected: Bool) {
        self.visibleThrough = visibleThrough
        self.isLooking = isLooking
        self.isCovered = isCovered
        self.hasLanded = hasLanded
        self.isMoving = isMoving
        self.isFinding = isFinding
        self.isConnected = isConnected
    }

    /// The sequence to mark read, or nil while the reader can't be reading.
    public var sequence: Int? {
        guard isLooking, !isCovered, hasLanded, !isMoving, !isFinding, isConnected else { return nil }
        return visibleThrough
    }

    /// Run it with `.task(id: read)`, so any change cancels the wait and starts it over.
    @MainActor
    public func mark(in store: ChannelStore,
                     sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async {
        guard let sequence else { return }
        do { try await sleep(Self.stillness) } catch { return }
        guard !Task.isCancelled else { return }
        await store.markRead(through: sequence)
    }
}
