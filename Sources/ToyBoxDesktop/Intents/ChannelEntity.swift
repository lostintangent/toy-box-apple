import AppIntents
import ChannelKit
import Foundation

/// A channel on the app's Toy Box server, as Siri, Shortcuts and Spotlight see it.
struct ChannelEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Channel", numericFormat: "\(placeholder: .int) channels")
    static let defaultQuery = ChannelQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Unread Count")
    var unreadCount: Int

    @Property(title: "Needs Your Reply")
    var needsReply: Bool

    @Property(title: "Tasks Completed")
    var tasksCompleted: Bool

    /// Matches the sidebar's indicator.
    let attention: ChannelAttention?

    init(_ channel: Channel) {
        self.init(id: channel.id, name: channel.name, attention: channelStatus(channel),
                  unreadCount: max(0, channel.latestSequence - channel.seenThrough))
    }

    /// A channel as a card remembers it, for its buttons.
    init(id: String, name: String, attention: ChannelAttention? = nil, unreadCount: Int = 0) {
        self.id = id
        self.attention = attention
        self.name = name
        self.unreadCount = unreadCount
        needsReply = attention == .waiting
        tasksCompleted = attention == .finished
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: subtitle,
            // The mark in the sidebar's channel icon.
            image: .init(systemName: "number")
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
}

/// Channels in the server's order, which is the sidebar's, found by name.
struct ChannelQuery: EntityStringQuery, EnumerableEntityQuery {
    @AppDependency var context: ChannelIntentsContext

    func entities(for identifiers: [String]) async throws -> [ChannelEntity] {
        let channels = try await context.entities()
        return identifiers.compactMap { id in channels.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [ChannelEntity] {
        ChannelQuery.matching(string, in: try await context.entities())
    }

    func suggestedEntities() async throws -> [ChannelEntity] {
        try await context.entities()
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
