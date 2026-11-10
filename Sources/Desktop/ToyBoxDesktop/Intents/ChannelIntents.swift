import AppIntents
import AppKit
import ChannelClient
import ChannelIntelligence
import ChannelKit
import Foundation

/// What Siri and Shortcuts use from the running app: its servers, their loaded catalogs, the
/// channel stores its windows share, its outbox, and the route a notification takes to open a
/// channel. Intents name channels from the loaded catalogs and save what they send to the outbox.
/// Reading never marks anything read.
@MainActor
final class ChannelIntents {
    struct Host {
        /// A server's API by its normalized address, while Settings lists it.
        var api: @MainActor (_ server: String) -> ChannelAPI?
        /// Every server's channels in Settings order once each server's catalog has loaded or
        /// failed, kept through a lost connection. Nil until then, and throws when none can load.
        var channels: @MainActor () throws -> [Listed]?
        var store: @MainActor (ChannelTarget) -> ChannelStore?
        /// Keeps a store connected while Catch Me Up reads it, shared with any window showing it.
        var hold: @MainActor (ChannelStore) -> Void
        var release: @MainActor (ChannelStore) -> Void
        /// Saves a message to the app's outbox, which shows it in its channel and delivers it.
        var send: @MainActor (Outgoing) async -> Void
        var open: @MainActor (ChannelTarget) -> Void
        /// The requests waiting for you once the catalogs have loaded, nil and throwing as `channels` does.
        var requests: @MainActor () throws -> [WaitingRequestEntry]? = { [] }
        /// Whether a channel's request is still waiting for you, by the app's waiting rule.
        var isWaiting: @MainActor (_ channel: ChannelTarget, _ request: Int) -> Bool = { _, _ in true }
        var revealRequest: @MainActor (ChannelTarget, Int) -> Void = { _, _ in }
        /// The channel or artifact in the frontmost window, which is all Siri may read.
        var onScreen: @MainActor () -> OnScreen? = { nil }
    }

    /// A channel as its server's catalog lists it.
    struct Listed: Equatable, Sendable {
        let target: ChannelTarget
        let channel: Channel

        /// Every server's channels in Settings order, once each server's catalog has loaded or
        /// failed. A server that can't load leaves only its own channels out.
        @MainActor static func all(in catalogs: [ChannelCatalogStore]) -> [Listed]? {
            guard catalogs.allSatisfy({ $0.isLoaded || $0.phase.failure != nil }) else { return nil }
            return catalogs.filter(\.isLoaded).flatMap { catalog in
                catalog.channels.compactMap { channel in
                    catalog.target(channel.id).map { Listed(target: $0, channel: channel) }
                }
            }
        }
    }

    /// The channel or artifact a window shows, with the stores behind it.
    enum OnScreen {
        case channel(ChannelStore)
        case artifact(ChannelArtifactSession, in: ChannelStore)
    }

    /// What a channel window shows Siri, which the app keeps for each window.
    @MainActor
    struct Screen {
        weak var window: NSWindow?
        let entity: ScreenEntity
        let artifacts: ChannelArtifactSession

        /// What Siri may read in a window: what it shows when it's a channel window, from its
        /// server's store for that channel, while the viewer still shows the artifact.
        static func onScreen(in window: NSWindow, screens: some Sequence<Screen>,
                             catalogs: [ChannelCatalogStore]) -> OnScreen? {
            guard let screen = screens.first(where: { $0.window === window }),
                  let catalog = catalogs.first(at: screen.entity.channel.serverURL),
                  let store = catalog.existingChannel(id: screen.entity.channel.channelID),
                  store.phase != .deleted else { return nil }
            switch screen.entity {
            case .channel:
                return .channel(store)
            case .artifact(_, let artifactID):
                let artifacts = screen.artifacts
                guard artifacts.channelID == store.id, artifacts.artifact?.id == artifactID,
                      !artifacts.isUnavailable else { return nil }
                return .artifact(artifacts, in: store)
            }
        }
    }

    private let host: Host
    /// Resolved on first use, because the live service loads the system model and the app
    /// registers these intents before its first window.
    private(set) lazy var intelligence: any ChannelIntelligenceService = makeIntelligence()
    private let makeIntelligence: @MainActor () -> any ChannelIntelligenceService
    /// The "Summarize new messages" setting. Off, Catch Me Up reads messages without the model.
    let summarizes: @MainActor () -> Bool
    /// Answers a send's confirmation in tests, where there's no system prompt to show.
    var confirmationOverride: (@MainActor (SendConfirmation) async throws -> Void)?
    var connectionTimeout: Duration
    var catchUpTimeout: Duration

    struct SendConfirmation: Equatable, Sendable {
        let channel: String
        let message: String
        /// The agent a reply mentions.
        let recipient: String?

        init(channel: String, message: String, recipient: String? = nil) {
            self.channel = channel
            self.message = message
            self.recipient = recipient
        }

        var question: String {
            let place = recipient.map { "\($0) in \(channel)" } ?? channel
            return "Send \u{201C}\(message)\u{201D} to \(place)?"
        }
    }

    /// A message an intent hands to the outbox.
    struct Outgoing: Equatable, Sendable {
        let text: String
        let channelID: String
        let server: URL
        /// The request it answers.
        let request: Int?
    }

    /// Spotlight's channels, kept only for the servers saved in Settings.
    private(set) var spotlight: ChannelSpotlight?
    private(set) var requestSpotlight: RequestSpotlight?

    init(host: Host,
         intelligence: @autoclosure @escaping @MainActor () -> any ChannelIntelligenceService = LiveChannelIntelligence.shared,
         summarizes: @escaping @MainActor () -> Bool = { true },
         connectionTimeout: Duration = .seconds(10), catchUpTimeout: Duration = .seconds(15)) {
        self.host = host
        makeIntelligence = intelligence
        self.summarizes = summarizes
        self.connectionTimeout = connectionTimeout
        self.catchUpTimeout = catchUpTimeout
    }

    // MARK: Channels

    /// Every server's channels. Right after launch they wait for each server's first catalog, so a
    /// slower server's channels aren't missing, and after that they stay through a lost connection,
    /// so Siri can still save a message to send.
    func channels() async throws -> [Listed] {
        if let channels = try await Self.first(within: connectionTimeout, host.channels) { return channels }
        throw ChannelIntentError.unreachable
    }

    func entities() async throws -> [ChannelEntity] {
        let channels = try await channels()
        let shown = shownChannel()
        return channels.map { listed in
            ChannelEntity(listed, content: shown?.target == listed.target ? shown?.content ?? "" : "")
        }
    }

    /// Siri asks for the channel on screen, which answers from its live store without a round trip.
    /// Any other channel keeps only what the sidebar shows, since a stale activity may still name
    /// it after you move on. A bare channel ID, which shortcuts saved before Toy Box had several
    /// servers, names the first server in Settings order that lists it.
    func entities(for identifiers: [String]) async throws -> [ChannelEntity] {
        if let shown = shownChannel(), identifiers == [shown.id] { return [shown] }
        let channels = try await entities()
        return identifiers.compactMap { id in
            channels.first { $0.id == id } ?? channels.first { $0.target.channelID == id }
        }
    }

    /// The channel on screen with its text, once its store has loaded.
    private func shownChannel() -> ChannelEntity? {
        guard case .channel(let store) = host.onScreen(), let channel = store.state?.channel,
              let target = store.target else { return nil }
        return ChannelEntity(Listed(target: target, channel: channel), content: store.readableText(name: channel.name))
    }

    /// The artifact on screen. One that has left the screen resolves to nothing, since only its
    /// viewer knows it.
    func artifacts(for identifiers: [String]) -> [ArtifactEntity] {
        guard case .artifact(let session, let store) = host.onScreen(), let artifact = session.artifact,
              !session.isUnavailable else { return [] }
        let entity = ArtifactEntity(artifact, in: store.id, content: session.readableText)
        return identifiers.contains(entity.id) ? [entity] : []
    }

    func channel(_ target: ChannelTarget) async throws -> Channel {
        guard let listed = try await channels().first(where: { $0.target == target }) else {
            throw ChannelIntentError.channelNotFound
        }
        return listed.channel
    }

    func open(_ target: ChannelTarget) {
        host.open(target)
    }

    /// Spotlight asks again for every channel, or for the named ones.
    func reindexSpotlight(_ ids: [String]?) async {
        await spotlight?.reindex(ids)
    }

    func waitingRequests() async throws -> [WaitingRequestEntity] {
        try await requests().map { entry in
            requestSpotlight?.entity(entry) ?? WaitingRequestEntity(entry, thumbnail: RequestSpotlight.renderAvatar(entry.agent))
        }
    }

    /// The requests waiting for you once the catalogs have loaded, or none if they haven't by the deadline.
    private func requests() async throws -> [WaitingRequestEntry] {
        try await Self.first(within: connectionTimeout, host.requests) ?? []
    }

    func reindexRequests(_ ids: [String]?) async {
        await requestSpotlight?.reindex(ids)
    }

    func openRequest(_ request: WaitingRequestEntry) async throws {
        guard try await requests().contains(where: { $0.id == request.id }) else {
            throw ChannelIntentError.requestNotWaiting
        }
        host.revealRequest(request.target, request.link.sequence)
    }

    /// The entity can outlive its request. Validate before and after confirmation, including the
    /// requester and its server, so a stale Spotlight action never answers a replacement question.
    func replyToRequest(_ request: WaitingRequestEntry, message: String,
                        confirm: @Sendable (SendConfirmation) async throws -> Void) async throws {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ChannelIntentError.emptyMessage }
        let waiting = try await requireWaiting(request)
        let prompt = SendConfirmation(channel: waiting.channelName, message: text, recipient: waiting.agent.name)
        if let confirmationOverride { try await confirmationOverride(prompt) } else { try await confirm(prompt) }
        guard try await requireWaiting(request).agent.name == waiting.agent.name,
              let server = host.api(request.target.serverURL)?.baseURL else {
            throw ChannelIntentError.requestNotWaiting
        }
        await host.send(.init(text: "@\(waiting.agent.handle) \(text)", channelID: request.target.channelID,
                              server: server, request: request.link.sequence))
    }

    /// The request as the app has it now, still waiting and asked by the same agent, whose current
    /// name the reply mentions.
    private func requireWaiting(_ request: WaitingRequestEntry) async throws -> WaitingRequestEntry {
        guard let current = try await requests().first(where: { $0.id == request.id }),
              current.agent.id == request.agent.id else {
            throw ChannelIntentError.requestNotWaiting
        }
        return current
    }

    // MARK: Catch Me Up

    /// One channel's catch-up, or a line for each channel that needs you when none is named.
    func catchUp(channel target: ChannelTarget?) async throws -> CatchUpAnswer.Answer {
        let channels = try await channels()
        if let target {
            guard let listed = channels.first(where: { $0.target == target }) else {
                throw ChannelIntentError.channelNotFound
            }
            return try await catchUp(listed)
        }
        let needing = CatchUpAnswer.needingAttention(channels)
        if needing.count == 1 { return try await catchUp(needing[0]) }
        var counts: [ChannelTarget: Int] = [:]
        for listed in needing.prefix(CatchUpAnswer.overviewRowLimit) where listed.channel.attention == .unread {
            counts[listed.target] = try? await newMessageCount(listed)
        }
        return CatchUpAnswer.overviewAnswer(needing, newMessages: counts)
    }

    private func catchUp(_ listed: Listed) async throws -> CatchUpAnswer.Answer {
        let channel = listed.channel
        guard channel.attention != nil else { return .init(spoken: CatchUpAnswer.caughtUp(in: channel.name)) }
        let state = try await connected(listed.target) { $0.state }
        guard let state else { throw ChannelIntentError.unreachable }
        let unreadAfter = state.channel.unreadAfter
        let digest = CatchUpDigest(state: state, unreadAfter: unreadAfter)
        var summary: (catchUp: CatchUp, count: Int)?
        if summarizes(), intelligence.availability.isAvailable, let api = host.api(listed.target.serverURL),
           let request = CatchUpRequest(server: api.baseURL, state: state, unreadAfter: unreadAfter),
           let catchUp = await summarize(request) {
            summary = (catchUp, request.unreadFromOthers)
        }
        return CatchUpAnswer.channelAnswer(state, on: listed.target, unreadAfter: unreadAfter, digest: digest,
                                           summary: summary)
    }

    /// The model's catch-up, shared with the transcript's card through the service's cache.
    private func summarize(_ request: CatchUpRequest) async -> CatchUp? {
        await intelligence.catchUp(request, within: catchUpTimeout)
    }

    /// New messages from agents in a channel that isn't open, from one page of history.
    private func newMessageCount(_ listed: Listed) async throws -> Int? {
        let channel = listed.channel
        guard let api = host.api(listed.target.serverURL), let unreadAfter = channel.unreadAfter else { return nil }
        let page = try await api.history(channelId: channel.id, before: channel.latestSequence + 1)
        guard let oldest = page.messages.first?.sequence, oldest <= unreadAfter + 1 else { return nil }
        return page.messages.agentMessageCount(after: unreadAfter)
    }

    // MARK: Send Message

    /// Confirms, then saves the message to the app's outbox, which shows it in the channel at once
    /// and delivers it once the server can take it. A reply mentions its recipient first, as the
    /// composer's Reply does, and answers `request` when the card names one. Returns the channel's
    /// name.
    @discardableResult
    func send(_ text: String, to target: ChannelTarget, recipient: String? = nil, answering request: Int? = nil,
              confirm: @Sendable (SendConfirmation) async throws -> Void) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChannelIntentError.emptyMessage }
        let channel = try await channel(target)
        guard let server = host.api(target.serverURL)?.baseURL else { throw ChannelIntentError.noServer }
        let prompt = SendConfirmation(channel: channel.name, message: trimmed, recipient: recipient)
        if let confirmationOverride { try await confirmationOverride(prompt) } else { try await confirm(prompt) }
        let content = recipient.map { "@\(ChannelAgent.handle(forName: $0)) \(trimmed)" } ?? trimmed
        await host.send(.init(text: content, channelID: target.channelID, server: server, request: request))
        return channel.name
    }

    /// The card with its request marked Replied once it's no longer waiting, which includes an
    /// answer still sending. It never connects a channel.
    func withReplies(_ card: CatchUpCard) -> CatchUpCard {
        guard let channel = card.channel, let request = card.reply?.request else { return card }
        var card = card
        card.isReplied = !host.isWaiting(channel, request)
        return card
    }

    // MARK: Connections

    /// Runs `body` while the channel's shared store is live, connecting it for the duration if no
    /// window has it open.
    private func connected<T>(_ target: ChannelTarget, _ body: (ChannelStore) async throws -> T) async throws -> T {
        guard let store = host.store(target) else { throw ChannelIntentError.noServer }
        host.hold(store)
        defer { host.release(store) }
        let state = try await Self.first(within: connectionTimeout) {
            if store.phase == .deleted { throw ChannelIntentError.channelNotFound }
            return store.phase.isConnected ? store.state : nil
        }
        guard state != nil else { throw ChannelIntentError.unreachable }
        return try await body(store)
    }

    /// What `read` gives once it isn't nil, read again whenever something it reads changes, or nil at
    /// the deadline. It throws what `read` throws.
    private static func first<T: Sendable>(within timeout: Duration,
                                           _ read: @escaping @MainActor () throws -> T?) async throws -> T? {
        if let value = try read() { return value }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                for try await value in Observations(read) { if let value { return value } }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}

extension ChannelIntents {
    /// The app's intents, which share its catalogs, stores and outbox with its windows, so a send
    /// appears in its channel at once and a failed one waits there for Send Again.
    convenience init(model: AppModel) {
        let channels: @MainActor () throws -> [Listed]? = {
            let catalogs = model.catalogs
            guard !catalogs.isEmpty else { throw ChannelIntentError.noServer }
            guard let channels = Listed.all(in: catalogs) else { return nil }
            guard catalogs.contains(where: \.isLoaded) else { throw ChannelIntentError.unreachable }
            return channels
        }
        self.init(host: Host(
            api: { model.catalogs.first(at: $0)?.api },
            channels: channels,
            store: { model.catalogs.first(at: $0.serverURL)?.channel(id: $0.channelID) },
            hold: { model.hold($0) },
            release: { model.release($0) },
            send: { message in
                await model.outbox.send(message.text, to: message.channelID, on: message.server,
                                        answering: message.request)
            },
            open: { model.activate($0) },
            requests: {
                guard try channels() != nil else { return nil }
                return model.menuBarStatus.waiting.compactMap(WaitingRequestEntry.init)
            },
            isWaiting: { channel, request in
                model.menuBarStatus.waiting.contains { $0.target == channel && $0.sequence == request }
            },
            revealRequest: { model.activate($0, sequence: $1) },
            onScreen: { model.onScreen }
        ), summarizes: { IntelligenceSettings.isOn(IntelligenceSettings.summarizesNewMessages) })
    }

    /// Makes the intents' dependency available. Call once, before the first intent runs.
    static func register(_ model: AppModel) {
        let context = ChannelIntents(model: model)
        AppDependencyManager.shared.add(dependency: context)
        guard !model.launchOptions.isSnapshot else { return }
        ShortcutParameters.observe(model)
        guard ChannelSpotlight.indexes(model.launchOptions) else { return }
        let spotlight = ChannelSpotlight()
        context.spotlight = spotlight
        spotlight.observe(model)
        let requests = RequestSpotlight()
        context.requestSpotlight = requests
        requests.observe(model)
    }
}

/// Siri learns channel names for phrases like "Catch me up on Studio demo in Toy Box" from the
/// shortcuts' parameters, refreshed whenever the set of names changes.
@MainActor
private enum ShortcutParameters {
    private static var registered: Set<String>?

    static func observe(_ model: AppModel) {
        let names = withObservationTracking {
            let loaded = model.catalogs.filter { $0.lastRefreshedAt != nil }
            return loaded.isEmpty ? nil : Set(loaded.flatMap { $0.channels.map(\.name) })
        } onChange: {
            Task { @MainActor in observe(model) }
        }
        guard let names, names != registered else { return }
        registered = names
        ToyBoxShortcuts.updateAppShortcutParameters()
    }
}

enum ChannelIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case noServer
    case unreachable
    case channelNotFound
    case emptyMessage
    case requestNotWaiting

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noServer: "Toy Box isn't connected to a server. Choose one in Settings."
        case .unreachable: "Can't connect to your Toy Box server. Check that it's running, then try again."
        case .channelNotFound: "That channel isn't on your Toy Box server anymore."
        case .emptyMessage: "There's nothing to send."
        case .requestNotWaiting: "That request is no longer waiting for your reply. Open the channel to see what's new."
        }
    }
}
