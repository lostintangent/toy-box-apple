import ChannelClient
import ChannelKit
import Foundation
import Observation
import OSLog
import SwiftUI
import ToyBoxMobileIntegrations
import ToyBoxUI
import UIKit

@MainActor @Observable
final class AppModel {
    let notifications: ChannelNotifications
    let following: ChannelFollowController
    /// The first server's address, or a launch address the app can't use.
    private(set) var serverURL = ""
    /// Every server, in Settings order.
    private(set) var catalogs: [ChannelCatalogStore] = []
    /// Every message the user sends until its server confirms it, in the shared container so the
    /// share extension's sends join it. Each server's catalog delivers its own.
    let outbox: ChannelOutbox
    private(set) var configurationError: String?
    private(set) var isActive = false
    private(set) var selectedStore: ChannelStore?
    private(set) var isResolvingNavigation = false
    /// The channel screen in front, on its server.
    var visibleChannel: ChannelTarget?
    /// What the visible channel screen shows, which Siri may read while it's in front.
    var screenEntity: ScreenEntity?
    var cover: Cover?
    var navigationNotice: String?
    /// The list's chosen channel, on its server.
    var selection: ChannelTarget? {
        didSet {
            guard oldValue != selection else { return }
            cancelNavigation()
            if let selectedStore {
                closeReaders(for: selectedStore.id)
            }
            if holdsSelectedConnection, let selectedStore { connections.release(selectedStore) }
            holdsSelectedConnection = false
            selectedStore = selection.flatMap { catalogs.first(at: $0.serverURL)?.channel(id: $0.channelID) }
            connectSelection()
            rememberSelection()
        }
    }

    @ObservationIgnored private let connections = ChannelConnections()
    @ObservationIgnored private(set) var isForeground = false
    @ObservationIgnored private var holdsSelectedConnection = false
    @ObservationIgnored private let defaults: UserDefaults
    /// A launch server stays in the session, so Settings never saves over the user's servers.
    @ObservationIgnored private let savesServers: Bool
    @ObservationIgnored private let session: URLSession
    /// The server whose last opened channel opens once its catalog loads, unless a navigation wins.
    @ObservationIgnored private weak var restoring: ChannelCatalogStore?
    @ObservationIgnored private var navigationGeneration = UUID()
    @ObservationIgnored private var interactions: [ChannelTarget: ChannelInteraction] = [:]
    @ObservationIgnored private var composerSessions: [String: ComposerSession] = [:]
    @ObservationIgnored private var artifactSessions: [String: (store: ChannelStore, session: ChannelArtifactSession)] = [:]
    @ObservationIgnored private var galleries: [String: (store: ChannelStore, gallery: TranscriptGallery)] = [:]
    @ObservationIgnored private var integrationsStarted = false
    /// When each server had last refreshed as the app resumed, by address. A server withdraws its
    /// stale notifications only once it's refreshed since.
    @ObservationIgnored private var resumeRefreshes: [String: Date] = [:]
    @ObservationIgnored private var widgetPublisher: MobileWidgetSnapshotPublisher?
    @ObservationIgnored private var shareHistory: MobileShareHistory?
    @ObservationIgnored private var badgeRefreshes: [Date] = []
    @ObservationIgnored private let integrationLogger = Logger(subsystem: "dev.toybox.mobile", category: "Integrations")

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         defaults: UserDefaults = .standard, session: URLSession = .shared,
         notifications: ChannelNotifications? = nil, following: ChannelFollowController? = nil) {
        self.notifications = notifications ?? ChannelNotifications(defaults: defaults)
        self.following = following ?? ChannelFollowController()
        self.defaults = defaults
        self.session = session
        let flag = arguments.firstIndex(of: "--server")
        let launchServer = flag.map { arguments.dropFirst($0 + 1).first ?? "" } ?? environment["TOY_BOX_SERVER_URL"]
        savesServers = launchServer == nil
        outbox = .mobile()
        self.notifications.onRegistrationCreated = { [weak self] registration in
            guard let self else { return }
            self.following.configure(servers: self.followedServers)
            await self.following.registrationCreated(registration)
        }
        self.notifications.onActivate = { [weak self] activation in
            await self?.openChannel(id: activation.channel.channelID, sequence: activation.channel.sequence,
                                    on: activation.serverURL)
        }
        self.notifications.onReply = { [weak self] reply in
            await self?.outbox.send(reply.content, to: reply.channelID, on: reply.server, answering: reply.request)
        }
        if let launchServer {
            do { catalogs = [connect(try ChannelAPI(serverURL: launchServer, session: session), name: nil)] }
            catch {
                serverURL = launchServer
                configurationError = flag != nil && launchServer.isEmpty
                    ? "Provide a server URL after --server." : error.localizedDescription
            }
        } else {
            catalogs = ChannelCatalogStore.Saved.load(from: defaults).compactMap { server in
                (try? ChannelAPI(serverURL: server.url, session: session)).map { connect($0, name: server.name) }
            }
        }
        if catalog != nil { firstServerDidChange() }
        serversDidChange()
        restoring = defaults.string(forKey: "lastServer").flatMap { catalogs.first(at: $0) } ?? catalog
    }

    /// The first server in Settings order.
    var catalog: ChannelCatalogStore? { catalogs.first }

    var api: ChannelAPI? { catalog?.api }

    /// The channel beneath a cover isn't visible, so it isn't read, notified as open or commanded.
    var isCovered: Bool { cover != nil }

    /// The channel or artifact Siri may read: what the channel screen shows, while the scene is in
    /// front and nothing covers it. Siri's own overlay makes the scene inactive, so this needs the
    /// foreground rather than the active scene.
    var onScreen: ChannelIntents.OnScreen? {
        guard isForeground, !isCovered, let screenEntity, let store = selectedStore,
              store.target == visibleChannel, screenEntity.channel == store.target, store.phase != .deleted
        else { return nil }
        switch screenEntity {
        case .channel:
            return .channel(store)
        case .artifact(_, let artifactID):
            guard let entry = artifactSessions[store.id], entry.store === store,
                  entry.session.artifact?.id == artifactID else { return nil }
            return .artifact(entry.session, in: store)
        }
    }

    var canManageChannels: Bool { canManageChannels(on: catalog) }

    /// Management needs the active scene and the channel's own server connected.
    func canManageChannels(on catalog: ChannelCatalogStore?) -> Bool { isActive && catalog?.phase == .connected }

    /// The selected channel's server, or the first one.
    var selectedServer: String { selection?.serverURL ?? serverURL }
    var canCreateChannel: Bool { canManageChannels(on: catalogs.first(at: selectedServer)) }

    var sidebarPresentation: ChannelSidebarPresentation { sidebarPresentation(for: catalog) }

    /// How the list shows a server's channels, given which of them is on screen.
    func sidebarPresentation(for catalog: ChannelCatalogStore?) -> ChannelSidebarPresentation {
        let open = openChannels.compactMap { catalog?.target($0.channelID) == $0 ? $0.channelID : nil }
        return ChannelSidebarPresentation(catalog: catalog, openChannelIDs: Set(open))
    }

    /// The channel on screen, whose live state the list and its requests read.
    var openChannels: Set<ChannelTarget> {
        let visible = isActive ? visibleChannel : nil
        return Set(visible.map { [$0] } ?? [])
    }

    func hold(_ store: ChannelStore) {
        connections.hold(store)
        if !isForeground { store.disconnect() }
    }

    func release(_ store: ChannelStore) { connections.release(store) }

    // MARK: Servers

    /// Adds a server, or finds the one already at that address.
    @discardableResult
    func addServer(_ address: String) throws -> ChannelCatalogStore {
        let api = try ChannelAPI(serverURL: address, session: session)
        if let listed = catalogs.first(at: api.baseURL.absoluteString) { return listed }
        let catalog = connect(api, name: nil)
        if catalogs.isEmpty { restoring = catalog }
        updateServers { $0.append(catalog) }
        return catalog
    }

    /// Replaces a server's live connections with another address, or finds the server already
    /// there. Drafts stay with the old address.
    @discardableResult
    func changeAddress(of catalog: ChannelCatalogStore, to address: String) throws -> ChannelCatalogStore {
        let api = try ChannelAPI(serverURL: address, session: session)
        if let listed = catalogs.first(at: api.baseURL.absoluteString) { return listed }
        guard let index = catalogs.firstIndex(where: { $0 === catalog }) else { return catalog }
        let moved = catalog.saved.moved(to: api.baseURL.absoluteString)
        disconnect(catalog)
        let replacement = connect(api, name: moved.name)
        updateServers { $0[index] = replacement }
        if selection == nil { restoring = replacement }
        return replacement
    }

    /// Disconnects a server and forgets it. The last one stays, so there's always a server.
    func removeServer(_ catalog: ChannelCatalogStore) {
        guard catalogs.count > 1, let index = catalogs.firstIndex(where: { $0 === catalog }) else { return }
        disconnect(catalog)
        updateServers { $0.remove(at: index) }
    }

    func moveServers(fromOffsets source: IndexSet, toOffset destination: Int) {
        updateServers { $0.move(fromOffsets: source, toOffset: destination) }
    }

    func rename(_ catalog: ChannelCatalogStore, to name: String) {
        catalog.name = catalog.saved.renamed(name).name
        updateServers { _ in }
    }

    private func connect(_ api: ChannelAPI, name: String?) -> ChannelCatalogStore {
        let catalog = ChannelCatalogStore(api: api, name: name)
        catalog.outbox = outbox
        if isForeground { catalog.startPolling() }
        return catalog
    }

    /// Closes a server's channels wherever they're open, and stops its connections.
    private func disconnect(_ catalog: ChannelCatalogStore) {
        let server = ChannelWaitingRequest.normalizedServer(catalog.api.baseURL.absoluteString)
        func belongs(_ store: ChannelStore) -> Bool { catalog.existingChannel(id: store.id) === store }
        if selection?.serverURL == server { selection = nil }
        if visibleChannel?.serverURL == server {
            visibleChannel = nil
            screenEntity = nil
        }
        for (target, interaction) in interactions where target.serverURL == server {
            interaction.isArtifactViewerPresented = false
            interactions[target] = nil
        }
        for (id, entry) in artifactSessions where belongs(entry.store) {
            entry.session.close()
            artifactSessions[id] = nil
        }
        for (id, entry) in galleries where belongs(entry.store) {
            entry.gallery.close()
            galleries[id] = nil
        }
        composerSessions = composerSessions.filter { !belongs($0.value.store) }
        catalog.stopPolling()
        catalog.outbox = nil
        connections.disconnectAll(in: catalog)
    }

    private func updateServers(_ change: (inout [ChannelCatalogStore]) -> Void) {
        let first = catalog
        change(&catalogs)
        if savesServers { ChannelCatalogStore.Saved.save(catalogs.map(\.saved), to: defaults) }
        if catalog !== first { firstServerDidChange() }
        serversDidChange()
    }

    /// The first server stands in for a launch address the app couldn't use, so a new one clears
    /// that error and any navigation in flight.
    private func firstServerDidChange() {
        cancelNavigation()
        serverURL = catalog?.api.baseURL.absoluteString ?? ""
        configurationError = nil
        navigationNotice = nil
    }

    /// Push and Share reach every server.
    private func serversDidChange() {
        notifications.configure(apis: catalogs.map(\.api))
        configureShareHistory()
    }

    /// Streams and catalog polling last until the scene enters the background, so Control Center,
    /// Notification Center or a glance at the app switcher never forces a reconnect. Marking read,
    /// management and treating the open channel as seen still need the active scene.
    func setScenePhase(_ phase: ScenePhase) {
        let foreground = phase != .background
        if isForeground != foreground {
            isForeground = foreground
            for catalog in catalogs { catalog.setActive(foreground) }
            if foreground {
                resumeRefreshes = Dictionary(catalogs.compactMap { catalog in
                    catalog.lastRefreshedAt.map { (catalog.api.baseURL.absoluteString, $0) }
                }, uniquingKeysWith: { first, _ in first })
                for catalog in catalogs { catalog.startPolling() }
                for store in connections.stores { store.connect() }
                connectSelection()
            } else {
                for catalog in catalogs { catalog.stopPolling() }
                for store in connections.stores { store.disconnect() }
            }
        }
        guard isActive != (phase == .active) else { return }
        isActive = phase == .active
        if isActive, notifications.registrationError != nil { notifications.retryRegistration() }
    }

    private func connectSelection() {
        guard isForeground, let selectedStore else { return }
        if holdsSelectedConnection {
            selectedStore.connect()
        } else {
            connections.hold(selectedStore)
            holdsSelectedConnection = true
        }
    }

    func reconcileSelection() {
        guard let catalog = restoring, !isResolvingNavigation, catalog.isLoaded else { return }
        restoring = nil
        guard selection == nil, let server = ChannelWaitingRequest.normalizedServer(catalog.api.baseURL.absoluteString),
              let id = rememberedSelections[server] else { return }
        if catalog.channels.contains(where: { $0.id == id }) {
            selection = catalog.target(id)
        } else {
            navigationNotice = "The channel you last opened is no longer available."
            var selections = rememberedSelections
            selections[server] = nil
            defaults.set(selections, forKey: "lastChannelByServer")
        }
    }

    /// Refreshes every server, or one whose Retry was chosen.
    func refreshCatalog(_ only: ChannelCatalogStore? = nil) async {
        await withDiscardingTaskGroup { group in
            for catalog in only.map({ [$0] }) ?? catalogs { group.addTask { await catalog.refresh() } }
        }
        reconcileSelection()
    }

    func startIntegrations() async {
        guard !integrationsStarted else { return }
        integrationsStarted = true
        observeFollowing()
        do {
            widgetPublisher = try MobileWidgetSnapshotPublisher()
        } catch {
            integrationLogger.error("Could not prepare the Needs You widget: \(error.localizedDescription)")
        }
        do {
            shareHistory = try MobileShareHistory()
        } catch {
            integrationLogger.error("Could not prepare share suggestions: \(error.localizedDescription)")
        }
        configureShareHistory()
        observeIntegrations()
        await notifications.start()
    }

    /// The share extension reads every server from this history, and suggests the channels each
    /// confirmed send went to.
    private func configureShareHistory() {
        guard let shareHistory else { return }
        shareHistory.select(servers: catalogs.map(\.saved))
        for catalog in catalogs {
            let serverURL = catalog.api.baseURL.absoluteString
            catalog.onSendConfirmed = { [weak shareHistory, weak catalog] id in
                guard let name = catalog?.channels.first(where: { $0.id == id })?.name else { return }
                shareHistory?.recordSend(serverURL: serverURL, channelID: id, name: name)
            }
        }
    }

    private func observeFollowing() {
        let servers = withObservationTracking { followedServers } onChange: { [weak self] in
            Task { @MainActor in self?.observeFollowing() }
        }
        following.configure(servers: servers)
    }

    /// Every server with its own push registration, so its channels can be followed once that's ready.
    private var followedServers: [ChannelFollowController.Server] {
        catalogs.map { catalog in
            let registration = notifications.registration(for: catalog.api.baseURL.absoluteString)
            return .init(catalog: catalog, registration: registration,
                         isRegistrationReady: notifications.isReady(registration),
                         registrationError: notifications.registrationError(for: registration))
        }
    }

    private func observeIntegrations() {
        let context = withObservationTracking {
            let active = isActive && !isCovered
                && selection.map({ interaction(for: $0).isArtifactViewerPresented != true }) != false
                ? visibleChannel : nil
            let channels = Dictionary(catalogs.map { catalog in
                (catalog.api.baseURL.absoluteString, catalog.channels.map(sidebarPresentation(for: catalog).channel))
            }, uniquingKeysWith: { first, _ in first })
            let withdrawing = catalogs.filter { catalog in
                isActive && catalog.isLoaded && catalog.phase.message == nil
                    && catalog.lastRefreshedAt != resumeRefreshes[catalog.api.baseURL.absoluteString]
            }
            return (channels: channels, active: active,
                    withdrawing: Set(withdrawing.map(\.api.baseURL.absoluteString)),
                    refreshes: catalogs.compactMap(\.lastRefreshedAt), registrations: notifications.registrations)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIntegrations() }
        }
        Task { [weak self] in
            await self?.notifications.update(channels: context.channels, activeChannel: context.active,
                                             withdrawing: context.withdrawing)
        }
        // A refresh on any server, or a loaded one leaving, writes every server's waiting count.
        if !context.refreshes.isEmpty, context.refreshes != badgeRefreshes {
            badgeRefreshes = context.refreshes
            notifications.updateBadge(catalogs.reduce(0) { $0 + $1.channels.count { $0.attention == .waiting } })
            for catalog in catalogs where catalog.lastRefreshedAt != nil {
                shareHistory?.prune(serverURL: catalog.api.baseURL.absoluteString, keeping: Set(catalog.channels.map(\.id)))
            }
        }
        do { try widgetPublisher?.update(catalogs: catalogs) }
        catch { integrationLogger.error("Could not update the Needs You widget: \(error.localizedDescription)") }
    }

    func beginHandoffNavigation() -> UUID {
        cancelNavigation()
        restoring = nil
        cover = nil
        navigationNotice = nil
        selection = nil
        return navigationGeneration
    }

    func openHandoffChannel(_ target: ChannelTarget, generation: UUID) {
        guard navigationGeneration == generation else { return }
        closeReaders(for: target.channelID)
        interaction(for: target).isInspectorPresented = false
        selection = target
    }

    /// Opens a channel on its server, from a notification, the widget or a request card.
    func openChannel(id: String, sequence: Int? = nil, focusComposer: Bool = false, on server: String) async {
        cancelNavigation()
        cover = nil
        guard let catalog = catalogs.first(at: server) else {
            navigationNotice = "This channel isn't available."
            return
        }
        let generation = UUID()
        navigationGeneration = generation
        isResolvingNavigation = true
        if !catalog.isLoaded { await catalog.refresh() }
        guard navigationGeneration == generation, catalogs.contains(where: { $0 === catalog }) else { return }
        isResolvingNavigation = false
        restoring = nil
        guard catalog.isLoaded, catalog.channels.contains(where: { $0.id == id }), let target = catalog.target(id) else {
            selection = nil
            navigationNotice = "This channel isn't available."
            return
        }
        let interaction = interaction(for: target)
        if let sequence {
            interaction.messageView = .all
            interaction.reveal(sequence: sequence)
        }
        closeReaders(for: id)
        interaction.isInspectorPresented = false
        if focusComposer { interaction.focusComposer() }
        navigationNotice = nil
        selection = target
    }

    func openExternalURL(_ url: URL) async {
        cancelNavigation()
        cover = nil
        if url == NeedsYouSnapshot.mainURL {
            restoring = nil
            selection = nil
        } else if let request = NeedsYouRequestLink(url: url) {
            await openChannel(id: request.channelID, sequence: request.sequence, on: request.serverURL)
        } else if let request = NeedsYouRequestLink(replyURL: url) {
            await openChannel(id: request.channelID, sequence: request.sequence, focusComposer: true,
                              on: request.serverURL)
        } else if let activity = ChannelActivityLink(url: url) {
            guard let registration = notifications.registration(id: activity.registrationID) else {
                navigationNotice = "This channel isn't available."
                return
            }
            await openChannel(id: activity.channelID, sequence: activity.sequence, on: registration.serverURL)
        } else {
            navigationNotice = "This link couldn't be opened."
        }
    }

    private func cancelNavigation() {
        navigationGeneration = UUID()
        isResolvingNavigation = false
    }

    func openInToyBox(_ channel: ChannelTarget) {
        guard let url = channelURL(channel) else { return }
        UIApplication.shared.open(url)
    }

    func channelURL(_ channel: ChannelTarget) -> URL? {
        catalogs.first(at: channel.serverURL)?.api.channelURL(channelID: channel.channelID)
    }

    func interaction(for channel: ChannelTarget) -> ChannelInteraction {
        if let interaction = interactions[channel] { return interaction }
        let interaction = ChannelInteraction(isInspectorPresented: false)
        interactions[channel] = interaction
        return interaction
    }

    func composerSession(for store: ChannelStore) -> ComposerSession {
        if let session = composerSessions[store.id], session.store === store { return session }
        let session = ComposerSession(store: store)
        composerSessions[store.id] = session
        return session
    }

    func artifactSession(for store: ChannelStore) -> ChannelArtifactSession {
        resetReaderScopeIfNeeded(for: store)
        if let entry = artifactSessions[store.id], entry.store === store { return entry.session }
        let session = ChannelArtifactSession(decodeImage: ArtifactImageDecoder.decode)
        session.configure(api: store.api, channelID: store.id, artifacts: store.artifacts)
        artifactSessions[store.id] = (store, session)
        return session
    }

    func gallery(for store: ChannelStore) -> TranscriptGallery {
        resetReaderScopeIfNeeded(for: store)
        if let entry = galleries[store.id], entry.store === store { return entry.gallery }
        let created = TranscriptGallery()
        galleries[store.id] = (store, created)
        return created
    }

    private func resetReaderScopeIfNeeded(for store: ChannelStore) {
        if artifactSessions[store.id].map({ $0.store !== store }) == true
            || galleries[store.id].map({ $0.store !== store }) == true {
            closeReaders(for: store.id)
            artifactSessions[store.id] = nil
            galleries[store.id] = nil
        }
    }

    private func closeReaders(for channelID: String) {
        artifactSessions[channelID]?.session.close()
        galleries[channelID]?.gallery.close()
        for (target, interaction) in interactions where target.channelID == channelID {
            interaction.isArtifactViewerPresented = false
        }
    }

    private var rememberedSelections: [String: String] {
        defaults.dictionary(forKey: "lastChannelByServer") as? [String: String] ?? [:]
    }

    /// Each server's last opened channel, and the server last opened, which launch restores.
    private func rememberSelection() {
        guard let selection else { return }
        var selections = rememberedSelections
        selections[selection.serverURL] = selection.channelID
        defaults.set(selections, forKey: "lastChannelByServer")
        defaults.set(selection.serverURL, forKey: "lastServer")
    }
}

extension AppModel {
    /// What the app presents over every channel. Only one at a time, and opening a channel from a
    /// notification, the widget or Handoff closes it.
    enum Cover: Hashable, Identifiable {
        case settings, screens
        /// One screen on a server, watched full screen, like a channel's screen preview.
        case screen(String, serverURL: String)

        var id: Self { self }
        var screenID: String? { if case .screen(let id, _) = self { id } else { nil } }
    }
}
