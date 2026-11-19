import ToyBoxClient
import ToyBoxKit
import SwiftUI

/// Opens the shared artifact a message's `file:` link names, in the channel a conversation shows.
/// Markdown reads the channel's artifacts only for a message with a file link, so the link follows
/// them as they're shared and removed, and other messages never redraw for them.
public struct TranscriptFileLinks: Equatable, Sendable {
    public let store: ChannelStore
    public let open: @MainActor @Sendable (ChannelArtifact) -> Void

    public init(store: ChannelStore, open: @escaping @MainActor @Sendable (ChannelArtifact) -> Void) {
        self.store = store
        self.open = open
    }

    /// The shared artifact `url` names, or nil for any other link.
    @MainActor func artifact(_ url: URL) -> ChannelArtifact? {
        FileReference(url)?.artifact(in: store.artifacts, folder: store.details?.directory)
    }

    /// Whoever sets this keeps one way to open artifacts for as long as it shows one channel.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.store === rhs.store }
}

private struct TranscriptFileLinksKey: EnvironmentKey {
    static let defaultValue: TranscriptFileLinks? = nil
}

extension EnvironmentValues {
    /// Set over a channel's conversation. Anywhere else, every `file:` link reads as plain text.
    public var transcriptFileLinks: TranscriptFileLinks? {
        get { self[TranscriptFileLinksKey.self] }
        set { self[TranscriptFileLinksKey.self] = newValue }
    }
}
