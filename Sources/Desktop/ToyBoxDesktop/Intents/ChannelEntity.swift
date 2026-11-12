import AppIntents
import ChannelKit
import CoreSpotlight
import CoreTransferable
import Foundation

/// A channel on one of the app's Toy Box servers, as Siri, Shortcuts and Spotlight see it. Its
/// identifier names the server, so the same channel ID on two servers stays two channels.
struct ChannelEntity: IndexedEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Channel", numericFormat: "\(placeholder: .int) channels")
    static let defaultQuery = ChannelQuery()

    let target: ChannelTarget
    var id: String { target.identifier }

    @Property(title: "Name")
    var name: String

    @Property(title: "Unread Count")
    var unreadCount: Int

    @Property(title: "Needs Your Reply")
    var needsReply: Bool

    @Property(title: "Tasks Completed")
    var tasksCompleted: Bool

    /// The name, purpose, tasks and newest loaded messages as plain text, only for the channel in
    /// the frontmost window. It's empty everywhere else, and Spotlight never gets it.
    @Property(title: "Content")
    var content: String

    /// Matches the sidebar's indicator.
    let attention: Channel.Attention?

    /// The first line of the channel's purpose, which Spotlight shows under its name.
    let purpose: String?

    /// The channel's avatar, which Spotlight shows beside the name.
    let thumbnail: Data?

    init(_ listed: ChannelIntents.Listed, content: String = "") {
        let channel = listed.channel
        self.init(listed.target, name: channel.name, attention: channel.attention,
                  unreadCount: max(0, channel.latestSequence - channel.seenThrough),
                  purpose: channel.purposePreview, content: content)
    }

    /// A channel as a card remembers it, for its buttons, or as Spotlight indexes it.
    init(_ target: ChannelTarget, name: String, attention: Channel.Attention? = nil, unreadCount: Int = 0,
         purpose: String? = nil, thumbnail: Data? = nil, content: String = "") {
        self.target = target
        self.attention = attention
        self.purpose = purpose
        self.thumbnail = thumbnail
        self.name = name
        self.unreadCount = unreadCount
        self.content = content
        needsReply = attention == .waiting
        tasksCompleted = attention == .finished
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: subtitle,
            // Spotlight shows the channel's avatar, and Siri and Shortcuts show the #.
            image: thumbnail.map { .init(data: $0) } ?? .init(systemName: "number")
        )
    }

    private var subtitle: LocalizedStringResource? {
        switch attention {
        case .waiting: "Needs your reply"
        case .finished: "All tasks completed"
        case .unread: "Unread messages"
        case nil: nil
        }
    }

    /// Spotlight keeps what it indexed, so it gets the name, purpose and icon but never the
    /// attention, which would go stale, or the content, which is only for what's on screen.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.displayName = name
        attributes.contentDescription = purpose
        return attributes
    }
}

extension ChannelEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { $0.content }
    }
}

/// Channels in Settings' server order, then each server's own, which is the sidebar's, found by
/// name. Only the channel in the frontmost window comes back with its text.
struct ChannelQuery: EntityStringQuery, EnumerableEntityQuery {
    @AppDependency var context: ChannelIntents

    func entities(for identifiers: [String]) async throws -> [ChannelEntity] {
        try await context.entities(for: identifiers)
    }

    func entities(matching string: String) async throws -> [ChannelEntity] {
        ChannelQuery.matching(string, in: try await context.entities())
    }

    func allEntities() async throws -> [ChannelEntity] {
        try await context.entities()
    }

    /// Exact names first, then names that start with the words, then names that contain them,
    /// ignoring case, accents and punctuation like "studio-demo" against "Studio demo".
    static func matching(_ string: String, in channels: [ChannelEntity]) -> [ChannelEntity] {
        let query = searchKey(string)
        guard !query.isEmpty else { return channels }
        let ranked: [(rank: Int, entity: ChannelEntity)] = channels.compactMap { channel in
            let name = searchKey(channel.name)
            if name == query { return (0, channel) }
            if name.hasPrefix(query) { return (1, channel) }
            if name.contains(query) { return (2, channel) }
            return nil
        }
        return ranked.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.entity)
    }

    static func searchKey(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Spotlight asks for channels again when it loses them. Only the servers saved in Settings fill
/// Spotlight, so a session-only launch ignores it.
extension ChannelQuery: IndexedEntityQuery {
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await context.reindexSpotlight(nil)
    }

    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        await context.reindexSpotlight(identifiers)
    }
}
