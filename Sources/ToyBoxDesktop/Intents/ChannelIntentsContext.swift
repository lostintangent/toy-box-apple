import AppIntents
import AppKit
import ChannelClient
import ChannelIntelligence
import ChannelKit
import Foundation

/// What Siri and Shortcuts use from the running app: its server, the channel stores its windows
/// share, and the route a notification takes to open a channel. Intents read the catalog fresh,
/// send through a channel's outbox, and never mark anything read.
@MainActor
final class ChannelIntentsContext {
    struct Host {
        var api: @MainActor () -> ChannelAPI?
        var store: @MainActor (String) -> ChannelStore?
        /// Keeps a store connected while an intent uses it, shared with any window showing it.
        var acquire: @MainActor (ChannelStore) -> Void
        var release: @MainActor (ChannelStore) -> Void
        var open: @MainActor (String) -> Void
    }

    private let host: Host
    /// Resolved on first use, because the live service loads the system model and the app
    /// registers this context before its first window.
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

    /// Requests answered from a card while the app runs, by channel.
    private var replies: [String: Set<Int>] = [:]

    /// Spotlight's channels, kept only for the server saved in Settings.
    private(set) var spotlight: ChannelSpotlight?

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

    func catalog() async throws -> ChannelCatalog {
        guard let api = host.api() else { throw ChannelIntentError.noServer }
        do { return try await api.catalog() }
        catch { throw ChannelIntentError.unreachable }
    }

    func entities() async throws -> [ChannelEntity] {
        try await catalog().channels.map(ChannelEntity.init)
    }

    func channel(_ id: String) async throws -> Channel {
        guard let channel = try await catalog().channels.first(where: { $0.id == id }) else {
            throw ChannelIntentError.channelNotFound
        }
        return channel
    }

    func open(_ id: String) {
        host.open(id)
    }

    /// Spotlight asks again for every channel, or for the named ones.
    func reindexSpotlight(_ ids: [String]?) async {
        await spotlight?.reindex(ids)
    }

    // MARK: Catch Me Up

    /// One channel's catch-up, or a line for each channel that needs you when none is named.
    func catchUp(channelID: String?) async throws -> CatchUpAnswer.Answer {
        let channels = try await catalog().channels
        if let channelID {
            guard let channel = channels.first(where: { $0.id == channelID }) else {
                throw ChannelIntentError.channelNotFound
            }
            return try await catchUp(channel)
        }
        let needing = CatchUpAnswer.needingAttention(channels)
        if needing.count == 1 { return try await catchUp(needing[0]) }
        var counts: [String: Int] = [:]
        for channel in needing.prefix(CatchUpAnswer.overviewRowLimit) where channelStatus(channel) == .unread {
            counts[channel.id] = try? await newMessageCount(channel)
        }
        return CatchUpAnswer.overviewAnswer(needing, newMessages: counts)
    }

    private func catchUp(_ channel: Channel) async throws -> CatchUpAnswer.Answer {
        guard channelStatus(channel) != nil else { return .init(spoken: CatchUpAnswer.caughtUp(in: channel.name)) }
        let state = try await connected(channel.id) { $0.state }
        guard let state else { throw ChannelIntentError.unreachable }
        let unreadAfter = channelUnreadAfter(state.channel)
        let digest = CatchUpDigest(state: state, unreadAfter: unreadAfter)
        var summary: (catchUp: CatchUp, count: Int)?
        if summarizes(), intelligence.availability.isAvailable, let api = host.api(),
           let request = CatchUpRequest(server: api.baseURL, state: state, unreadAfter: unreadAfter),
           let catchUp = await summarize(request) {
            summary = (catchUp, request.unreadFromOthers)
        }
        return CatchUpAnswer.channelAnswer(state, unreadAfter: unreadAfter, digest: digest, summary: summary)
    }

    /// The model's catch-up, shared with the transcript's card through the service's cache.
    private func summarize(_ request: CatchUpRequest) async -> CatchUp? {
        let service = intelligence
        let timeout = catchUpTimeout
        return await withTaskGroup(of: CatchUpResult?.self) { group in
            group.addTask { await service.catchUp(request) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first?.catchUp
        }
    }

    /// New messages from agents in a channel that isn't open, from one page of history.
    private func newMessageCount(_ channel: Channel) async throws -> Int? {
        guard let api = host.api(), let unreadAfter = channelUnreadAfter(channel) else { return nil }
        let page = try await api.history(channelId: channel.id, before: channel.latestSequence + 1)
        guard let oldest = page.messages.first?.sequence, oldest <= unreadAfter + 1 else { return nil }
        return page.messages.filter { $0.sequence > unreadAfter && !$0.isSystem && $0.sender.type == "agent" }.count
    }

    // MARK: Send Message

    /// Confirms, then makes one attempt through the channel's outbox under a caller-owned ID. A
    /// failed attempt waits in the channel for Send Again. A reply mentions its recipient first, as
    /// the composer's Reply does. Returns the channel's name.
    func send(_ text: String, id: String = UUID().uuidString, to channelID: String, recipient: String? = nil,
              confirm: @Sendable (SendConfirmation) async throws -> Void) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChannelIntentError.emptyMessage }
        let channel = try await channel(channelID)
        let prompt = SendConfirmation(channel: channel.name, message: trimmed, recipient: recipient)
        if let confirmationOverride { try await confirmationOverride(prompt) } else { try await confirm(prompt) }
        let content = recipient.map { "@\(agentHandleFromName($0)) \(trimmed)" } ?? trimmed
        return try await connected(channelID) { store in
            do {
                try await store.post(id: id, content: content)
                return channel.name
            } catch {
                if store.phase == .deleted { throw ChannelIntentError.channelDeleted(channel.name) }
                switch store.sendAttempts.first(where: { $0.id == id })?.phase {
                case .deliveryNotConfirmed: throw ChannelIntentError.notConfirmed(channel.name)
                case .notSent: throw ChannelIntentError.waitingToSend(channel.name)
                default: throw ChannelIntentError.notSent(channel.name)
                }
            }
        }
    }

    /// Sends a card's reply, then remembers the request it answers so the card shows it as Replied.
    @discardableResult
    func reply(_ text: String, id: String = UUID().uuidString, to channelID: String, recipient: String?,
               request: Int?, confirm: @Sendable (SendConfirmation) async throws -> Void) async throws -> String {
        let name = try await send(text, id: id, to: channelID, recipient: recipient, confirm: confirm)
        if let request { replies[channelID, default: []].insert(request) }
        return name
    }

    /// The card with its request marked Replied once you've answered it, here or in a window that
    /// has the channel open. It never connects a channel.
    func withReplies(_ card: CatchUpCard) -> CatchUpCard {
        guard let channelID = card.channelID, let request = card.reply?.request else { return card }
        var card = card
        card.isReplied = replies[channelID]?.contains(request) == true
            || host.store(channelID)?.state.map { TranscriptCatchUp.isReplied(request, in: $0.messages) } == true
        return card
    }

    // MARK: Connections

    /// Runs `body` while the channel's shared store is live, connecting it for the duration if no
    /// window has it open.
    private func connected<T>(_ channelID: String, _ body: (ChannelStore) async throws -> T) async throws -> T {
        guard let store = host.store(channelID) else { throw ChannelIntentError.noServer }
        host.acquire(store)
        defer { host.release(store) }
        let deadline = ContinuousClock.now + connectionTimeout
        while !store.phase.isLive || store.state == nil {
            if store.phase == .deleted { throw ChannelIntentError.channelNotFound }
            guard ContinuousClock.now < deadline else { throw ChannelIntentError.unreachable }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await body(store)
    }
}

extension ChannelIntentsContext {
    /// The app's context. Its stores are the ones its windows show, so a send appears in an open
    /// channel at once and a failed one waits there for Send Again.
    convenience init(model: AppModel) {
        self.init(host: Host(
            api: { model.api },
            store: { model.catalog?.channel(id: $0) },
            acquire: { model.acquire($0) },
            release: { model.release($0) },
            open: { id in
                NSApplication.shared.activate()
                model.navigationRequest = .init(channelID: id, sequence: nil)
                if model.activeChannelID == nil { model.openChannelWindow?(id) }
            }
        ), summarizes: { TranscriptIntelligenceSettings.isOn(TranscriptIntelligenceSettings.summarizesNewMessages) })
    }

    /// Makes the intents' dependency available. Call once, before the first intent runs.
    static func register(_ model: AppModel) {
        let context = ChannelIntentsContext(model: model)
        AppDependencyManager.shared.add(dependency: context)
        guard !model.launchOptions.isSnapshot else { return }
        ShortcutParameters.observe(model)
        guard ChannelSpotlight.indexes(model.launchOptions) else { return }
        let spotlight = ChannelSpotlight()
        context.spotlight = spotlight
        spotlight.observe(model)
    }
}

/// Siri learns channel names for phrases like "Catch me up on Studio demo in Toy Box" from the
/// shortcuts' parameters, refreshed whenever the set of names changes.
@MainActor
private enum ShortcutParameters {
    private static var registered: Set<String>?

    static func observe(_ model: AppModel) {
        let names = withObservationTracking {
            model.catalog.flatMap { $0.lastRefreshedAt == nil ? nil : Set($0.channels.map(\.name)) }
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
    case channelDeleted(String)
    case emptyMessage
    case notSent(String)
    case waitingToSend(String)
    case notConfirmed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noServer: "Toy Box Desktop isn't connected to a server. Choose one in Settings."
        case .unreachable: "Can't connect to your Toy Box server. Check that it's running, then try again."
        case .channelNotFound: "That channel isn't on your Toy Box server anymore."
        case .channelDeleted(let name): "\(name) was deleted, so your message wasn't sent."
        case .emptyMessage: "There's nothing to send."
        case .notSent(let name): "Your message to \(name) wasn't sent. Try again in a moment."
        case .waitingToSend(let name): "Your message to \(name) wasn't sent. It's waiting in the channel so you can send it again."
        case .notConfirmed(let name): "Your Toy Box server didn't confirm your message to \(name). Open the channel to see if it arrived before you send it again."
        }
    }
}
