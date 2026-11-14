import AppIntents
import ToyBoxClient
import ToyBoxKit
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
    private let catalogs: @MainActor () -> [ChannelCatalogStore]

    init(onScreen: @escaping @MainActor () -> OnScreen?, catalogs: @escaping @MainActor () -> [ChannelCatalogStore]) {
        self.onScreen = onScreen
        self.catalogs = catalogs
    }

    convenience init(model: AppModel) {
        self.init(onScreen: { model.onScreen }, catalogs: { model.catalogs })
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
        let catalogs = catalogs()
        return identifiers.compactMap { identifier in
            guard let target = ChannelTarget(identifier: identifier) else { return nil }
            let name = catalogs.first(at: target.serverURL)?.channels.first { $0.id == target.channelID }?.name
            if let shown, shown.target == target {
                let name = shown.details?.name ?? name ?? ""
                return ChannelEntity(target, name: name, content: shown.readableText(name: name))
            }
            return name.map { ChannelEntity(target, name: $0) }
        }
    }

    /// The artifact on screen. One that has left the screen resolves to nothing, since only its
    /// viewer knows it.
    func artifacts(for identifiers: [String]) -> [ArtifactEntity] {
        guard case .artifact(let session, let store) = onScreen(), let artifact = session.artifact,
              !session.isUnavailable else { return [] }
        let entity = ArtifactEntity(artifact, in: store.id, content: session.readableText)
        return identifiers.contains(entity.id) ? [entity] : []
    }
}
