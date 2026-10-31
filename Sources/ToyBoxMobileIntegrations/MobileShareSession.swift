import ChannelClient
import ChannelKit
import Foundation
import Intents
import Observation

/// The share extension's one message: where it goes, what it carries, and its single send attempt.
/// It posts by itself, since an iOS share extension can't open its app.
@MainActor @Observable
public final class MobileShareSession {
    public struct Target: Equatable, Sendable {
        public let id: String
        public let name: String
    }

    public enum Phase: Equatable, Sendable {
        case composing, sending, sent
        /// The message is locked, so Send Again repeats the same attempt and can't post it twice.
        case unconfirmed, offline
    }

    /// The server the app saved, or nil until the app has connected once.
    public let serverURL: String?
    public let catalog: ChannelCatalogStore?
    public let recentChannelIDs: [String]
    public private(set) var content: MobileShareContent?
    public private(set) var contentError: String?
    public private(set) var phase = Phase.composing
    /// Why the last send posted nothing. The message stays editable.
    public private(set) var notice: String?
    /// Nil until a channel is chosen, which the share sheet shows as the channel list.
    public private(set) var target: Target?
    public var note = ""

    @ObservationIgnored private let history: MobileShareHistory?
    /// What Send Again repeats: the first Send's ID and the exact message it posted.
    @ObservationIgnored private var attempt: (id: String, message: String)?
    @ObservationIgnored private var store: ChannelStore?

    /// `intent` is the suggestion the share sheet opened from. One for another server, or a channel
    /// the server no longer lists, leaves no channel chosen.
    public init(history: MobileShareHistory?, intent: INSendMessageIntent?, session: URLSession = .shared) {
        self.history = history
        let server = history?.serverURL
        let api = server.flatMap { try? ChannelAPI(serverURL: $0, session: session) }
        serverURL = api == nil ? nil : server
        catalog = api.map { ChannelCatalogStore(api: $0) }
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
        guard target != nil, let content, [.composing, .unconfirmed, .offline].contains(phase) else { return false }
        return !content.attachments.isEmpty || !content.message(note: note).isEmpty
    }

    /// The lead first, then the channel's members, as the audience pill reads them.
    public var agents: [ChannelAgent] {
        guard let target else { return [] }
        return ChannelSidebarProjection(catalog: catalog, openChannelIDs: []).catalogAgents(channelID: target.id)
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
        notice = nil
    }

    /// The first Send makes the attempt's ID and Send Again reuses it. A refusal or a deleted channel
    /// posted nothing, so the message unlocks and its next Send is a new attempt.
    public func send() async {
        guard canSend, let target, let content, let catalog, let serverURL else { return }
        let attempt = self.attempt ?? (UUID().uuidString, content.message(note: note))
        self.attempt = attempt
        let store: ChannelStore
        if let existing = self.store, existing.id == target.id { store = existing } else {
            store = ChannelStore(id: target.id, api: catalog.api, sendJournal: nil)
            self.store = store
        }
        phase = .sending
        notice = nil
        do {
            try await store.postInBackground(id: attempt.id, content: attempt.message,
                                             attachments: content.attachments)
            phase = .sent
            await history?.recordSend(serverURL: serverURL, channelID: target.id, name: target.name).value
        } catch {
            if case ChannelAPIError.http(status: 404, _) = error {
                self.attempt = nil
                phase = .composing
                notice = "\(target.name) no longer exists. Choose another channel."
                self.target = nil
                await catalog.refresh()
            } else if store.lastSendFailure?.messageId == attempt.id, store.lastSendFailure?.phase == .notSent {
                self.attempt = nil
                phase = .composing
                if case ChannelAPIError.http(_, let message) = error { notice = message }
                else { notice = error.localizedDescription }
            } else {
                phase = Self.isOffline(error) ? .offline : .unconfirmed
            }
        }
    }

    static func isOffline(_ error: any Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(code)
    }
}
