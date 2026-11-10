import AppIntents
import ChannelClient
import ChannelKit
import CoreTransferable
import Foundation

/// A channel as Siri sees it while it's on screen. The text lives in Content, which the query fills
/// only for the channel on screen, so Siri reads what the user is looking at and nothing else. Its
/// identifier names the server, so the same channel ID on two servers stays two channels.
struct ChannelEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Channel", numericFormat: "\(placeholder: .int) channels")
    static let defaultQuery = ChannelQuery()

    let target: ChannelTarget
    var id: String { target.identifier }

    @Property(title: "Name")
    var name: String

    /// The name, purpose, tasks and newest loaded messages as plain text, or empty off screen.
    @Property(title: "Content")
    var content: String

    init(_ target: ChannelTarget, name: String, content: String = "") {
        self.target = target
        self.name = name
        self.content = content
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
