import AppIntents
import ChannelKit
import CoreSpotlight
import Foundation

/// What Spotlight shows of a waiting request, so only a change to it re-adds the request, not a
/// working agent's status or the channel's activity.
struct WaitingRequestEntry: Equatable, Sendable {
    let id: String
    let target: ChannelTarget
    let link: NeedsYouRequestLink
    let question: String
    let agent: ChannelAgent
    let channelName: String
    let requestedAt: Date?

    init?(_ request: ChannelWaitingRequest) {
        guard let agent = request.requester else { return nil }
        let link = NeedsYouRequestLink(serverURL: request.target.serverURL, channelID: request.target.channelID,
                                       sequence: request.sequence)
        guard let url = link.url, NeedsYouRequestLink(url: url) != nil else { return nil }
        id = url.absoluteString
        target = request.target
        self.link = link
        question = request.question
        self.agent = ChannelAgent(id: agent.id, name: agent.name, avatar: agent.avatar, deleted: agent.deleted)
        channelName = request.channel.name
        requestedAt = request.requestedAt
    }
}

struct WaitingRequestEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Waiting Request")
    static let defaultQuery = WaitingRequestQuery()

    let entry: WaitingRequestEntry
    let thumbnail: Data?
    var id: String { entry.id }

    @Property(title: "Question")
    var question: String

    @Property(title: "Agent")
    var agentName: String

    @Property(title: "Channel")
    var channelName: String

    init(_ entry: WaitingRequestEntry, thumbnail: Data? = nil) {
        self.entry = entry
        self.thumbnail = thumbnail
        question = entry.question
        agentName = entry.agent.name
        channelName = entry.channelName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(question)", subtitle: "\(agentName) \u{00b7} \(channelName)",
                              image: thumbnail.map { .init(data: $0) } ?? .init(systemName: "questionmark.bubble"))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = question
        attributes.displayName = question
        attributes.contentDescription = "\(agentName) \u{00b7} \(channelName)"
        attributes.keywords = [agentName, channelName, "Needs your reply"]
        attributes.contentCreationDate = entry.requestedAt
        return attributes
    }
}

struct WaitingRequestQuery: EntityStringQuery, EnumerableEntityQuery, IndexedEntityQuery {
    @AppDependency var context: ChannelIntents

    func entities(for identifiers: [String]) async throws -> [WaitingRequestEntity] {
        let requests = try await context.waitingRequests()
        return identifiers.compactMap { id in requests.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [WaitingRequestEntity] {
        Self.matching(string, in: try await context.waitingRequests())
    }

    func allEntities() async throws -> [WaitingRequestEntity] { try await context.waitingRequests() }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await context.reindexRequests(nil)
    }

    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        await context.reindexRequests(identifiers)
    }

    static func matching(_ string: String, in requests: [WaitingRequestEntity]) -> [WaitingRequestEntity] {
        let query = ChannelQuery.searchKey(string)
        guard !query.isEmpty else { return requests }
        return requests.filter {
            ChannelQuery.searchKey([$0.question, $0.agentName, $0.channelName].joined(separator: " ")).contains(query)
        }
    }
}
