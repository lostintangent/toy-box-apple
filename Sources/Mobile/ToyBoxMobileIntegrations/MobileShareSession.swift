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
        public let id: String
        public let name: String
    }

    public enum Phase: Equatable, Sendable {
        case composing, sending, sent
    }

    /// The server the app saved, or nil until the app has connected once.
    public let serverURL: String?
    public let catalog: ChannelCatalogStore?
    public let recentChannelIDs: [String]
    public private(set) var content: MobileShareContent?
    public private(set) var contentError: String?
    public private(set) var phase = Phase.composing
    /// Nil until a channel is chosen, which the share sheet shows as the channel list.
    public private(set) var target: Target?
    public var note = ""

    @ObservationIgnored private let history: MobileShareHistory?
    @ObservationIgnored private let outbox: ChannelOutbox?

    /// `intent` is the suggestion the share sheet opened from. One for another server, or a channel
    /// the server no longer lists, leaves no channel chosen. Tests pass their own `outbox`.
    public init(history: MobileShareHistory?, intent: INSendMessageIntent?, session: URLSession = .shared,
                outbox: ChannelOutbox? = nil) {
        self.history = history
        let server = history?.serverURL
        let api = server.flatMap { try? ChannelAPI(serverURL: $0, session: session) }
        serverURL = api == nil ? nil : server
        catalog = api.map { ChannelCatalogStore(api: $0) }
        self.outbox = api == nil ? nil : outbox ?? .mobile(sendsOnce: true)
        catalog?.outbox = self.outbox
        recentChannelIDs = history?.recentChannelIDs ?? []
        if let server, let identifier = intent?.conversationIdentifier,
           let suggested = MobileShareTarget(conversationIdentifier: identifier),
           suggested.serverURL == ChannelWaitingRequest.normalizedServer(server) {
            target = Target(id: suggested.channelID,
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
        return ChannelSidebarPresentation(catalog: catalog, openChannelIDs: []).catalogAgents(channelID: target.id)
    }

    /// Reads what was shared while the channel list loads.
    public func start(_ providers: sending [NSItemProvider], title: String?) async {
        let channels = Task { await refreshChannels() }
        do { content = try await MobileShareContent.load(providers, title: title) }
        catch { contentError = error.localizedDescription }
        await channels.value
    }

    public func refreshChannels() async {
        guard let catalog else { return }
        await catalog.refresh()
        guard catalog.isLoaded, phase == .composing, let id = target?.id else { return }
        target = catalog.channels.first { $0.id == id }.map { Target(id: id, name: $0.name) }
    }

    public func choose(_ channel: Channel) {
        guard !isLocked else { return }
        target = Target(id: channel.id, name: channel.name)
    }

    /// Returns once the one attempt settles, even offline, and the app shows any failure in the channel.
    public func send() async {
        guard canSend, let target, let content, let catalog, let outbox, let serverURL else { return }
        phase = .sending
        await outbox.send(content.message(note: note), attachments: content.attachments,
                          to: target.id, on: catalog.api.baseURL)
        phase = .sent
        await history?.recordSend(serverURL: serverURL, channelID: target.id, name: target.name).value
    }
}
