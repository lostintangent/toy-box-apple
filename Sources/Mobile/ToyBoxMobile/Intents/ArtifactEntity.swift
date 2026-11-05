import AppIntents
import ChannelClient
import ChannelKit
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

    init(_ artifact: ChannelArtifact, in channelID: String, content loaded: ArtifactContent?) {
        id = Self.id(channelID: channelID, artifactID: artifact.id)
        let kind = ArtifactContentKind(artifact)
        title = artifact.title
        self.kind = kind.label(for: artifact)
        let text = kind == .markdown && loaded?.artifact.id == artifact.id ? loaded?.text ?? "" : ""
        content = MarkdownBlock.plainText(text).clipped(to: ChannelEntity.contentLimit)
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
