import ChannelClient
import ChannelKit
import Foundation
import Intents
import Observation

/// The share extension's one message: where it goes and what it carries. Sending saves it to the
/// shared outbox and makes one attempt while the sheet shows Sending. Whatever that doesn't settle,
/// the app shows and sends at its next launch.
@MainActor @Observable
public final class MobileShareSession {
    public struct Target: Equatable, Sendable {
        /// The address of the server the channel is on.
        public let serverURL: String
        public let id: String
        public let name: String
    }

    /// A channel the sheet offers, on its server.
    public struct Choice: Identifiable {
        public let catalog: ChannelCatalogStore
        public let channel: Channel
        public let id: String

        @MainActor init(catalog: ChannelCatalogStore, channel: Channel) {
            self.catalog = catalog
            self.channel = channel
            id = "\(catalog.api.baseURL.absoluteString) \(channel.id)"
        }
    }

    public enum Phase: Equatable, Sendable {
        case composing, sending, sent
    }

    /// One per server the app saved, in Settings order, and none until the app has connected once.
    public let catalogs: [ChannelCatalogStore]
    public let recents: [ChannelTarget]
    public private(set) var content: MobileShareContent?
    public private(set) var contentError: String?
    public private(set) var phase = Phase.composing
    /// Nil until a channel is chosen, which the share sheet shows as the channel list.
    public private(set) var target: Target?
    public var note = ""

    @ObservationIgnored private let history: MobileShareHistory?
    @ObservationIgnored private let outbox: ChannelOutbox?

    /// `intent` is the suggestion the share sheet opened from. One for a server the app doesn't have,
    /// or a channel its server no longer lists, leaves no channel chosen. Tests pass their own `outbox`.
    public init(history: MobileShareHistory?, intent: INSendMessageIntent?, session: URLSession = .shared,
                outbox: ChannelOutbox? = nil) {
        self.history = history
        catalogs = (history?.servers ?? []).compactMap { saved in
            (try? ChannelAPI(serverURL: saved.url, session: session)).map { ChannelCatalogStore(api: $0, name: saved.name) }
        }
        self.outbox = catalogs.isEmpty ? nil : outbox ?? .mobile(sendsOnce: true)
        for catalog in catalogs { catalog.outbox = self.outbox }
        recents = history?.recents ?? []
        if let identifier = intent?.conversationIdentifier, let suggested = ChannelTarget(identifier: identifier),
           let catalog = catalogs.first(at: suggested.serverURL) {
            target = Target(serverURL: catalog.api.baseURL.absoluteString, id: suggested.channelID,
                            name: intent?.speakableGroupName?.spokenPhrase ?? suggested.channelID)
        }
    }

    public var isLocked: Bool { phase != .composing }

    public var canSend: Bool {
        guard target != nil, let content, phase == .composing else { return false }
        return !content.attachments.isEmpty || !content.message(note: note).isEmpty
    }

    /// The lead first, then the channel's members, as the audience pill reads them.
    public var agents: [ChannelAgent] {
        guard let target else { return [] }
        return ChannelSidebarPresentation(catalog: catalogs.first(at: target.serverURL), openChannelIDs: [])
            .catalogAgents(channelID: target.id)
    }

    /// Up to three recent channels across every server, then each server's others A to Z, which with
    /// one server is `choices(matching:recentIDs:)`.
    public func choices(matching query: String) -> (recent: [Choice], others: [[Choice]]) {
        let latest = recents.prefix(3)
        let addresses = catalogs.map { ChannelWaitingRequest.normalizedServer($0.api.baseURL.absoluteString) }
        let perServer = zip(catalogs, addresses).map { catalog, address in
            catalog.channels.choices(matching: query,
                                     recentIDs: latest.filter { $0.serverURL == address }.map(\.channelID))
        }
        let recent = latest.compactMap { target -> Choice? in
            guard let index = addresses.firstIndex(of: target.serverURL),
                  let channel = perServer[index].recent.first(where: { $0.id == target.channelID }) else { return nil }
            return Choice(catalog: catalogs[index], channel: channel)
        }
        return (recent, zip(catalogs, perServer).map { catalog, choices in
            choices.others.map { Choice(catalog: catalog, channel: $0) }
        })
    }

    /// Reads what was shared while the channel list loads.
    public func start(_ providers: sending [NSItemProvider], title: String?) async {
        let channels = Task { await refreshChannels() }
        do { content = try await MobileShareContent.load(providers, title: title) }
        catch { contentError = error.localizedDescription }
        await channels.value
    }

    public func refreshChannels() async {
        await withTaskGroup(of: Void.self) { group in
            for catalog in catalogs { group.addTask { await catalog.refresh() } }
        }
        guard phase == .composing, let target, let catalog = catalogs.first(at: target.serverURL),
              catalog.isLoaded else { return }
        self.target = catalog.channels.first { $0.id == target.id }.map {
            Target(serverURL: target.serverURL, id: target.id, name: $0.name)
        }
    }

    public func choose(_ choice: Choice) {
        guard !isLocked else { return }
        target = Target(serverURL: choice.catalog.api.baseURL.absoluteString, id: choice.channel.id,
                        name: choice.channel.name)
    }

    /// Returns once the one attempt settles, even offline, and the app shows any failure in the channel.
    public func send() async {
        guard canSend, let target, let content, let outbox,
              let catalog = catalogs.first(at: target.serverURL) else { return }
        phase = .sending
        await outbox.send(content.message(note: note), attachments: content.attachments,
                          to: target.id, on: catalog.api.baseURL)
        phase = .sent
        await history?.recordSend(serverURL: target.serverURL, channelID: target.id, name: target.name).value
    }
}
