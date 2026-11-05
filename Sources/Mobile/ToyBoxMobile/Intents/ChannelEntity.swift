import AppIntents
import ChannelClient
import CoreTransferable
import Foundation

/// A channel as Siri sees it while it's on screen. The text lives in Content, which the query fills
/// only for the channel on screen, so Siri reads what the user is looking at and nothing else.
struct ChannelEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Channel", numericFormat: "\(placeholder: .int) channels")
    static let defaultQuery = ChannelQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    /// The name, purpose, tasks and newest loaded messages as plain text, or empty off screen.
    @Property(title: "Content")
    var content: String

    init(id: String, name: String, content: String = "") {
        self.id = id
        self.name = name
        self.content = content
    }

    @MainActor init(_ store: ChannelStore, name: String) {
        self.init(id: store.id, name: name, content: store.readableText(name: name))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "number"))
    }
}

extension ChannelEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { $0.content }
    }
}

/// Resolves the identifier the screen's user activity carries. Only the channel on screen comes
/// back with its text.
struct ChannelQuery: EntityQuery {
    @AppDependency var intents: ChannelIntents

    init() {}

    /// Tests resolve through their own intents. The dependency resolves itself only inside Siri's
    /// own requests, unless it's set first.
    init(intents: ChannelIntents) {
        _intents.wrappedValue = intents
    }

    func entities(for identifiers: [String]) async throws -> [ChannelEntity] {
        await intents.channels(for: identifiers)
    }
}
