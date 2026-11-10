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
    var visibleChannelID: String?
    /// What the visible channel screen shows, which Siri may read while it's in front.
    var screenEntity: ScreenEntity?
    var cover: Cover?
    var navigationNotice: String?
    var selectedChannelID: String? {
        didSet {
            guard oldValue != selectedChannelID else { return }
            cancelNavigation()
            if let selectedStore {
                closeReaders(for: selectedStore.id)
            }
            if holdsSelectedConnection, let selectedStore { connections.release(selectedStore) }
            holdsSelectedConnection = false
            selectedStore = selectedChannelID.flatMap { catalog?.channel(id: $0) }
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
    @ObservationIgnored private var restoredSelection = false
    @ObservationIgnored private var navigationGeneration = UUID()
    @ObservationIgnored private var serverIdentity = ""
    @ObservationIgnored private var interactions: [String: ChannelInteraction] = [:]
    @ObservationIgnored private var composerSessions: [String: ComposerSession] = [:]
    @ObservationIgnored private var artifactSessions: [String: (store: ChannelStore, session: ChannelArtifactSession)] = [:]
    @ObservationIgnored private var galleries: [String: (store: ChannelStore, gallery: TranscriptGallery)] = [:]
    @ObservationIgnored private var integrationsStarted = false
    @ObservationIgnored private var integrationsGeneration = UUID()
    @ObservationIgnored private var resumeCatalogBaseline: Date?
    @ObservationIgnored private var widgetPublisher: MobileWidgetSnapshotPublisher?
    @ObservationIgnored private var shareHistory: MobileShareHistory?
    @ObservationIgnored private var badgeRefresh: Date?
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
            guard let self, self.notifications.currentRegistration == registration,
                  self.serverURL == registration.serverURL else { return }
            self.configureFollowing()
            await self.following.registrationCreated(registration)
        }
        self.notifications.onActivate = { [weak self] activation in
            await self?.openChannel(id: activation.channel.channelID, sequence: activation.channel.sequence,
                                    expectedServer: activation.serverURL)
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
    }

    /// The first server, which the list and everything outside Settings show until each reaches
    /// its own.
    var catalog: ChannelCatalogStore? { catalogs.first }

    var api: ChannelAPI? { catalog?.api }

    /// The channel beneath a cover isn't visible, so it isn't read, notified as open or commanded.
    var isCovered: Bool { cover != nil }

    /// The channel or artifact Siri may read: what the channel screen shows, while the scene is in
    /// front and nothing covers it. Siri's own overlay makes the scene inactive, so this needs the
    /// foreground rather than the active scene.
    var onScreen: ChannelIntents.OnScreen? {
        guard isForeground, !isCovered, let screenEntity, let store = selectedStore,
              store.id == visibleChannelID, screenEntity.channelID == store.id, store.phase != .deleted
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

    var sidebarFooter: SidebarFooter { SidebarFooter(phase: catalog?.phase, isLoaded: catalog?.isLoaded == true) }

    var canManageChannels: Bool { isActive && catalog?.phase == .connected }
    var canCreateChannel: Bool { canManageChannels }

    var sidebarPresentation: ChannelSidebarPresentation {
        ChannelSidebarPresentation(catalog: catalog, openChannelIDs: openChannelIDs)
    }

    /// The channel on screen, whose live state the list and its requests read.
    var openChannelIDs: Set<String> {
        let visible = isActive ? visibleChannelID : nil
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

    private func disconnect(_ catalog: ChannelCatalogStore) {
        catalog.stopPolling()
        catalog.outbox = nil
        connections.disconnectAll(in: catalog)
    }

    private func updateServers(_ change: (inout [ChannelCatalogStore]) -> Void) {
        let first = catalog
        change(&catalogs)
        if savesServers { ChannelCatalogStore.Saved.save(catalogs.map(\.saved), to: defaults) }
        if catalog !== first { firstServerDidChange() }
    }

    /// The list and everything outside Settings show the first server, so a new first server
    /// starts them over.
    private func firstServerDidChange() {
        integrationsGeneration = UUID()
        badgeRefresh = nil
        cancelNavigation()
        selectedChannelID = nil
        visibleChannelID = nil
        screenEntity = nil
        for id in Set(artifactSessions.keys).union(galleries.keys) { closeReaders(for: id) }
        interactions = [:]
        composerSessions = [:]
        artifactSessions = [:]
        galleries = [:]
        serverURL = catalog?.api.baseURL.absoluteString ?? ""
        serverIdentity = ChannelWaitingRequest.normalizedServer(serverURL) ?? ""
        if let api { notifications.configure(api: api) }
        configurationError = nil
        navigationNotice = nil
        restoredSelection = false
        resumeCatalogBaseline = nil
        if integrationsStarted {
            configureShareHistory()
            observeIntegrations(generation: integrationsGeneration)
        }
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
                resumeCatalogBaseline = catalog?.lastRefreshedAt
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
        guard !restoredSelection, !isResolvingNavigation, let catalog, catalog.isLoaded else { return }
        restoredSelection = true
        guard selectedChannelID == nil, let id = rememberedSelections[serverIdentity] else { return }
        if catalog.channels.contains(where: { $0.id == id }) {
            selectedChannelID = id
        } else {
            navigationNotice = "The channel you last opened is no longer available."
            var selections = rememberedSelections
            selections[serverIdentity] = nil
            defaults.set(selections, forKey: "lastChannelByServer")
        }
    }

    func refreshCatalog() async {
        guard let catalog else { return }
        await catalog.refresh()
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
        observeIntegrations(generation: integrationsGeneration)
        await notifications.start()
    }

    /// The share extension reads the server from this history, and suggests the channels each
    /// confirmed send went to.
    private func configureShareHistory() {
        guard let shareHistory, let catalog else { return }
        let serverURL = catalog.api.baseURL.absoluteString
        shareHistory.select(servers: [catalog.saved])
        catalog.onSendConfirmed = { [weak shareHistory, weak catalog] id in
            guard let name = catalog?.channels.first(where: { $0.id == id })?.name else { return }
            shareHistory?.recordSend(serverURL: serverURL, channelID: id, name: name)
        }
    }

    private func observeFollowing() {
        withObservationTracking {
            _ = notifications.currentRegistration
            _ = notifications.isRegistrationReady
            _ = notifications.registrationError
            _ = catalogs
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeFollowing() }
        }
        configureFollowing()
    }

    /// Every server's channels can be followed once its push registration is ready. Push registers
    /// only the first server so far.
    private func configureFollowing() {
        following.configure(servers: catalogs.enumerated().map { index, catalog in
            index > 0 ? .init(catalog: catalog) : .init(
                catalog: catalog, registration: notifications.currentRegistration,
                isRegistrationReady: notifications.isRegistrationReady,
                registrationError: notifications.registrationError)
        })
    }

    private func observeIntegrations(generation: UUID) {
        guard generation == integrationsGeneration else { return }
        let context = withObservationTracking {
            let channels = catalog?.channels.map(sidebarPresentation.channel) ?? []
            let active = isActive && !isCovered
                && selectedStore.map({ interaction(for: $0.id).isArtifactViewerPresented != true }) != false
                ? visibleChannelID : nil
            return (channels: channels, active: active,
                    withdraw: isActive && catalog?.isLoaded == true && catalog?.phase.message == nil
                        && catalog?.lastRefreshedAt != resumeCatalogBaseline,
                    refreshed: catalog?.lastRefreshedAt, failure: catalog?.phase.message,
                    registration: notifications.currentRegistration?.registrationID)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIntegrations(generation: generation) }
        }
        Task { [weak self] in
            guard let self, generation == integrationsGeneration else { return }
            await notifications.update(channels: context.channels, activeChannelID: context.active,
                                       withdraw: context.withdraw)
        }
        if let catalog, catalog.phase.message == nil, let refreshed = catalog.lastRefreshedAt,
           refreshed != badgeRefresh {
            badgeRefresh = refreshed
            notifications.updateBadge(catalog.channels.filter { $0.attention == .waiting }.count)
            shareHistory?.prune(serverURL: catalog.api.baseURL.absoluteString, keeping: Set(catalog.channels.map(\.id)))
        }
        do { try widgetPublisher?.update(catalogs: catalog.map { [$0] } ?? []) }
        catch { integrationLogger.error("Could not update the Needs You widget: \(error.localizedDescription)") }
    }

    func beginHandoffNavigation() -> UUID {
        cancelNavigation()
        restoredSelection = true
        cover = nil
        navigationNotice = nil
        selectedChannelID = nil
        return navigationGeneration
    }

    func openHandoffChannel(id: String, generation: UUID) {
        guard navigationGeneration == generation else { return }
        closeReaders(for: id)
        interaction(for: id).isInspectorPresented = false
        selectedChannelID = id
    }

    func openChannel(id: String, sequence: Int? = nil, focusComposer: Bool = false,
                     expectedServer: String) async {
        cancelNavigation()
        cover = nil
        guard expectedServer == serverURL, let catalog else {
            navigationNotice = "This channel isn't available."
            return
        }
        let generation = UUID()
        navigationGeneration = generation
        isResolvingNavigation = true
        if !catalog.isLoaded { await catalog.refresh() }
        guard navigationGeneration == generation, self.catalog === catalog else { return }
        isResolvingNavigation = false
        restoredSelection = true
        guard catalog.isLoaded, catalog.channels.contains(where: { $0.id == id }) else {
            selectedChannelID = nil
            navigationNotice = "This channel isn't available."
            return
        }
        let interaction = interaction(for: id)
        if let sequence {
            interaction.messageView = .all
            interaction.reveal(sequence: sequence)
        }
        closeReaders(for: id)
        interaction.isInspectorPresented = false
        if focusComposer { interaction.focusComposer() }
        navigationNotice = nil
        selectedChannelID = id
    }

    func openExternalURL(_ url: URL) async {
        cancelNavigation()
        cover = nil
        if url == NeedsYouSnapshot.mainURL {
            restoredSelection = true
            selectedChannelID = nil
        } else if let request = NeedsYouRequestLink(url: url) {
            await openChannel(id: request.channelID, sequence: request.sequence,
                              expectedServer: request.serverURL)
        } else if let request = NeedsYouRequestLink(replyURL: url) {
            await openChannel(id: request.channelID, sequence: request.sequence, focusComposer: true,
                              expectedServer: request.serverURL)
        } else if let activity = ChannelActivityLink(url: url) {
            guard let registration = notifications.currentRegistration,
                  registration.registrationID == activity.registrationID else {
                navigationNotice = "This channel isn't available."
                return
            }
            await openChannel(id: activity.channelID, sequence: activity.sequence,
                              expectedServer: registration.serverURL)
        } else {
            navigationNotice = "This link couldn't be opened."
        }
    }

    private func cancelNavigation() {
        navigationGeneration = UUID()
        isResolvingNavigation = false
    }

    func openInToyBox(channelID: String) {
        guard let url = channelURL(channelID: channelID) else { return }
        UIApplication.shared.open(url)
    }

    func channelURL(channelID: String) -> URL? {
        api?.channelURL(channelID: channelID)
    }

    func interaction(for channelID: String) -> ChannelInteraction {
        if let interaction = interactions[channelID] { return interaction }
        let interaction = ChannelInteraction(isInspectorPresented: false)
        interactions[channelID] = interaction
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
        interactions[channelID]?.isArtifactViewerPresented = false
    }

    private var rememberedSelections: [String: String] {
        defaults.dictionary(forKey: "lastChannelByServer") as? [String: String] ?? [:]
    }

    private func rememberSelection() {
        guard let selectedChannelID else { return }
        var selections = rememberedSelections
        selections[serverIdentity] = selectedChannelID
        defaults.set(selections, forKey: "lastChannelByServer")
    }
}

extension AppModel {
    /// What the app presents over every channel. Only one at a time, and opening a channel from a
    /// notification, the widget or Handoff closes it.
    enum Cover: Hashable, Identifiable {
        case settings, screens
        /// One screen watched full screen, like a channel's screen preview.
        case screen(String)

        var id: Self { self }
        var screenID: String? { if case .screen(let id) = self { id } else { nil } }
    }
}
