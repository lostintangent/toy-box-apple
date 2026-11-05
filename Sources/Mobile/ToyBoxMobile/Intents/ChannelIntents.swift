import AppIntents
import ChannelClient
import ChannelKit
import Foundation

/// Siri's view of the phone: the channel or artifact on screen, which is all it may read. The
/// screen's user activity names that entity, and Siri resolves it through the entities' queries,
/// which ask this.
@MainActor
final class ChannelIntents {
    /// The channel or artifact the foreground scene shows, with the stores behind it.
    enum OnScreen {
        case channel(ChannelStore)
        case artifact(ChannelArtifactSession, in: ChannelStore)
    }

    private let onScreen: @MainActor () -> OnScreen?
    private let catalog: @MainActor () -> [Channel]

    init(onScreen: @escaping @MainActor () -> OnScreen?, catalog: @escaping @MainActor () -> [Channel]) {
        self.onScreen = onScreen
        self.catalog = catalog
    }

    convenience init(model: AppModel) {
        self.init(onScreen: { model.onScreen }, catalog: { model.catalog?.channels ?? [] })
    }

    /// Makes the queries' dependency available. Call once, before the first query runs.
    static func register(_ model: AppModel) {
        let intents = ChannelIntents(model: model)
        AppDependencyManager.shared.add(dependency: intents)
    }

    /// The channel on screen with its text. Any other channel keeps only its name, since a stale
    /// activity may still name it after the user moves on.
    func channels(for identifiers: [String]) -> [ChannelEntity] {
        let shown: ChannelStore? = if case .channel(let store) = onScreen() { store } else { nil }
        let channels = catalog()
        return identifiers.compactMap { id in
            let name = channels.first { $0.id == id }?.name
            if let shown, shown.id == id { return ChannelEntity(shown, name: shown.details?.name ?? name ?? "") }
            return name.map { ChannelEntity(id: id, name: $0) }
        }
    }

    /// The artifact on screen. One that has left the screen resolves to nothing, since only its
    /// viewer knows it.
    func artifacts(for identifiers: [String]) -> [ArtifactEntity] {
        guard case .artifact(let session, let store) = onScreen(), let artifact = session.artifact,
              !session.isUnavailable else { return [] }
        let entity = ArtifactEntity(artifact, in: store.id, content: session.content)
        return identifiers.contains(entity.id) ? [entity] : []
    }
}

extension String {
    /// At most `limit` characters, cut at a word with an ellipsis when it's longer.
    func clipped(to limit: Int) -> String {
        guard count > limit else { return self }
        let prefix = self.prefix(limit - 1)
        let cut = prefix.lastIndex(where: \.isWhitespace).map { prefix[..<$0] } ?? prefix
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }
}
