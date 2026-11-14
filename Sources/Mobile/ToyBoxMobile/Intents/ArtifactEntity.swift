import AppIntents
import ToyBoxClient
import ToyBoxKit
import CoreTransferable
import Foundation

/// An artifact open in the channel's viewer, as Siri sees it. Like the channel, its text lives in
/// Content only while it's on screen.
struct ArtifactEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Artifact", numericFormat: "\(placeholder: .int) artifacts")
    static let defaultQuery = ArtifactQuery()

    /// The channel's ID, then the artifact's, since an artifact's ID is unique only in its channel.
    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Kind")
    var kind: String

    /// A Markdown artifact's text with its formatting flattened. Other kinds give only their title
    /// and kind: HTML is the raw page, scripts and all, and images and files have no text.
    @Property(title: "Content")
    var content: String

    init(_ artifact: ChannelArtifact, in channelID: String, content: String) {
        id = Self.id(channelID: channelID, artifactID: artifact.id)
        title = artifact.title
        kind = ArtifactContentKind(artifact).label(for: artifact)
        self.content = content
    }

    static func id(channelID: String, artifactID: String) -> String { "\(channelID)/\(artifactID)" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(kind)", image: .init(systemName: "doc.text"))
    }
}

extension ArtifactEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { $0.content }
    }
}

/// Resolves the identifier the screen's user activity carries while an artifact is open.
struct ArtifactQuery: EntityQuery {
    @AppDependency var intents: ChannelIntents

    init() {}

    /// Tests resolve through their own intents. The dependency resolves itself only inside Siri's
    /// own requests, unless it's set first.
    init(intents: ChannelIntents) {
        _intents.wrappedValue = intents
    }

    func entities(for identifiers: [String]) async throws -> [ArtifactEntity] {
        await intents.artifacts(for: identifiers)
    }
}
