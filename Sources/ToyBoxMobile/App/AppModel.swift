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
    private(set) var serverURL = ""
    private(set) var catalog: ChannelCatalogStore?
    private(set) var configurationError: String?
    private(set) var isActive = false
    private(set) var selectedStore: ChannelStore?
    private(set) var isResolvingNavigation = false
    var visibleChannelID: String?
    var isSettingsPresented = false
    var navigationNotice: String?
    var browserFailure: BrowserFailure?
    let requestedRefresh = RequestedCatalogRefresh()
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

    @ObservationIgnored private let connections = ChannelConnections<ChannelStore>()
    @ObservationIgnored private var holdsSelectedConnection = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var restoredSelection = false
    @ObservationIgnored private var navigationGeneration = UUID()
    @ObservationIgnored private var serverIdentity = ""
    @ObservationIgnored private var interactions: [String: ChannelInteraction] = [:]
    @ObservationIgnored private var composerSessions: [String: ComposerSession] = [:]
    @ObservationIgnored private var artifactSessions: [String: (store: ChannelStore, session: ChannelArtifactSession)] = [:]
    @ObservationIgnored private var galleryPresenters: [String: (store: ChannelStore, presenter: TranscriptGalleryPresenter)] = [:]
    @ObservationIgnored private var integrationsStarted = false
    @ObservationIgnored private var integrationsGeneration = UUID()
    @ObservationIgnored private var resumeCatalogBaseline: Date?
    @ObservationIgnored private var widgetPublisher: MobileWidgetSnapshotPublisher?
    @ObservationIgnored private var widgetUpdate: Task<Void, Never>?
    @ObservationIgnored private var widgetUpdateRequested = false
    @ObservationIgnored private let integrationLogger = Logger(subsystem: "dev.toybox.mobile", category: "Integrations")

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         bundleDefaultServerURL: String? = Bundle.main.object(forInfoDictionaryKey: "ToyBoxDefaultServerURL") as? String,
         defaults: UserDefaults = .standard, session: URLSession = .shared,
         notifications: ChannelNotifications? = nil, following: ChannelFollowController? = nil) {
        self.notifications = notifications ?? ChannelNotifications(defaults: defaults)
        self.following = following ?? ChannelFollowController()
        self.defaults = defaults
        self.session = session
        self.notifications.onRegistrationCreated = { [weak self] registration in
            guard let self, self.notifications.currentRegistration == registration,
                  self.serverURL == registration.serverURL else { return }
            self.configureFollowing()
            await self.following.registrationCreated(registration)
        }
        self.notifications.onActivate = { [weak self] activation in
            await self?.openChannel(id: activation.channelID, sequence: activation.sequence,
                                    expectedServer: activation.serverURL)
        }
        self.notifications.onReply = { [weak self] payload, text, handle in
            guard let self, self.notifications.isCurrent(payload), let catalog else { return .notSent }
            let result = await ComposerNotificationReply.send(
                text, to: handle, store: catalog.channel(id: payload.channelID),
                isCurrentRegistration: { [weak self] in
                    self?.catalog === catalog && self?.notifications.isCurrent(payload) == true
                })
            if result == .sent { await catalog.refresh() }
            return result
        }
        let address: String?
        if let index = arguments.firstIndex(of: "--server") {
            guard arguments.indices.contains(index + 1) else {
                configurationError = "Provide a server URL after --server."
                return
            }
            address = arguments[index + 1]
        } else {
            address = environment["TOY_BOX_SERVER_URL"] ?? defaults.string(forKey: "serverURL") ?? bundleDefaultServerURL
        }
        guard let address else { return }
        do { try configure(serverURL: address, persist: false) }
        catch {
            serverURL = address
            configurationError = error.localizedDescription
        }
    }

    var api: ChannelAPI? { catalog?.api }

    var sidebarConnection: SidebarConnection {
        SidebarConnection(
            loaded: catalog?.hasLoaded == true, failing: catalog?.error != nil,
            fatal: catalog == nil || SidebarConnection.isFatal(catalog?.failure)
        )
    }

    var canManageChannels: Bool { isActive && sidebarConnection == .connected }
    var canCreateChannel: Bool { canManageChannels }

    var sidebarProjection: ChannelSidebarProjection {
        let visible = isActive ? visibleChannelID : nil
        return ChannelSidebarProjection(catalog: catalog, openChannelIDs: Set(visible.map { [$0] } ?? []))
    }

    func acquire(_ store: ChannelStore) {
        connections.acquire(store)
        if !isActive { store.disconnect() }
    }

    func release(_ store: ChannelStore) { connections.release(store) }

    func switchServer(to address: String, replacing expectedServer: String) throws {
        guard serverURL == expectedServer else { throw ServerSwitchFailure.changed }
        try configure(serverURL: address)
    }

    func configure(serverURL: String, persist: Bool = true) throws {
        let api = try ChannelAPI(serverURL: serverURL, session: session)
        guard let identity = ChannelWaitingRequest.normalizedServer(api.baseURL.absoluteString) else {
            throw ChannelAPIError.invalidServerURL
        }
        integrationsGeneration = UUID()
        widgetUpdate?.cancel()
        widgetUpdate = nil
        cancelNavigation()
        catalog?.stopPolling()
        connections.disconnectAll()
        holdsSelectedConnection = false
        selectedChannelID = nil
        visibleChannelID = nil
        for id in Set(artifactSessions.keys).union(galleryPresenters.keys) { closeReaders(for: id) }
        interactions = [:]
        composerSessions = [:]
        artifactSessions = [:]
        galleryPresenters = [:]
        self.serverURL = api.baseURL.absoluteString
        serverIdentity = identity
        catalog = ChannelCatalogStore(api: api)
        notifications.configure(api: api)
        configurationError = nil
        navigationNotice = nil
        browserFailure = nil
        restoredSelection = false
        resumeCatalogBaseline = nil
        if persist { defaults.set(self.serverURL, forKey: "serverURL") }
        if isActive { catalog?.startPolling() }
        if integrationsStarted { observeIntegrations(generation: integrationsGeneration) }
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active { resumeCatalogBaseline = catalog?.lastRefreshedAt }
        catalog?.setActive(active)
        if active {
            catalog?.startPolling()
            for store in connections.stores { store.connect() }
            connectSelection()
        } else {
            catalog?.stopPolling()
            for store in connections.stores { store.disconnect() }
        }
    }

    private func connectSelection() {
        guard isActive, let selectedStore else { return }
        if holdsSelectedConnection {
            selectedStore.connect()
        } else {
            connections.acquire(selectedStore)
            holdsSelectedConnection = true
        }
    }

    func reconcileSelection() {
        guard !restoredSelection, !isResolvingNavigation, let catalog, catalog.hasLoaded else { return }
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
        await requestedRefresh.run(catalog)
        reconcileSelection()
    }

    func startIntegrations() async {
        guard !integrationsStarted else { return }
        integrationsStarted = true
        observeFollowing()
        do {
            widgetPublisher = try MobileWidgetSnapshotPublisher(avatarPNG: Self.widgetAvatar)
        } catch {
            integrationLogger.error("Could not prepare the Needs You widget: \(error.localizedDescription)")
        }
        await notifications.start()
        observeIntegrations(generation: integrationsGeneration)
    }

    private func observeFollowing() {
        withObservationTracking {
            _ = notifications.currentRegistration
            _ = notifications.isRegistrationReady
            _ = catalog
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeFollowing() }
        }
        configureFollowing()
    }

    private func configureFollowing() {
        following.configure(
            registration: notifications.currentRegistration, isRegistrationReady: notifications.isRegistrationReady,
            catalog: catalog
        )
    }

    private func observeIntegrations(generation: UUID) {
        guard generation == integrationsGeneration else { return }
        let context = withObservationTracking {
            let channels = catalog?.channels.map(sidebarProjection.channel) ?? []
            let active = isActive && !isSettingsPresented
                && selectedStore.map({ interaction(for: $0.id).isArtifactViewerPresented != true }) != false
                ? visibleChannelID : nil
            return (channels: channels, active: active,
                    withdraw: isActive && catalog?.hasLoaded == true && catalog?.error == nil
                        && catalog?.lastRefreshedAt != resumeCatalogBaseline,
                    refreshed: catalog?.lastRefreshedAt, failure: catalog?.error,
                    registration: notifications.currentRegistration?.registrationID)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIntegrations(generation: generation) }
        }
        Task { [weak self] in
            guard let self, generation == integrationsGeneration else { return }
            await notifications.update(channels: context.channels, activeChannelID: context.active,
                                       withdraw: context.withdraw)
        }
        updateWidget(generation: generation)
    }

    private func updateWidget(generation: UUID) {
        guard widgetPublisher != nil else { return }
        widgetUpdateRequested = true
        guard widgetUpdate == nil else { return }
        widgetUpdate = Task { [weak self] in
            guard let self, generation == integrationsGeneration, !Task.isCancelled else { return }
            repeat {
                widgetUpdateRequested = false
                do {
                    try await widgetPublisher?.update(catalog: catalog, serverURL: serverURL)
                } catch {
                    if Task.isCancelled || error is CancellationError
                        || (error as? URLError)?.code == .cancelled { break }
                    integrationLogger.error("Could not update the Needs You widget: \(error.localizedDescription)")
                }
            } while widgetUpdateRequested && generation == integrationsGeneration && !Task.isCancelled
            if generation == integrationsGeneration { widgetUpdate = nil }
        }
    }

    private static func widgetAvatar(_ agent: ChannelAgent) -> Data? {
        let renderer = ImageRenderer(content: AgentAvatarView(agent: agent, size: 24))
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }

    func beginHandoffNavigation() -> UUID {
        cancelNavigation()
        restoredSelection = true
        isSettingsPresented = false
        navigationNotice = nil
        browserFailure = nil
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
        guard expectedServer == serverURL, let catalog else {
            navigationNotice = "This channel isn't available."
            return
        }
        let generation = UUID()
        navigationGeneration = generation
        isResolvingNavigation = true
        if !catalog.hasLoaded { await requestedRefresh.run(catalog) }
        guard navigationGeneration == generation, self.catalog === catalog else { return }
        isResolvingNavigation = false
        restoredSelection = true
        guard catalog.hasLoaded, catalog.channels.contains(where: { $0.id == id }) else {
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
        guard let api, let url = api.channelURL(channelID: channelID) else {
            browserFailure = BrowserFailure(
                url: nil, message: "A link to this channel couldn't be created. Check the server address in Settings."
            )
            return
        }
        Task {
            let opened = await UIApplication.shared.open(url)
            guard self.api?.baseURL == api.baseURL else { return }
            if !opened {
                browserFailure = BrowserFailure(
                    url: url, message: "The browser couldn't open this channel. You can copy its link and try again."
                )
            }
        }
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

    func galleryPresenter(for store: ChannelStore) -> TranscriptGalleryPresenter {
        resetReaderScopeIfNeeded(for: store)
        if let entry = galleryPresenters[store.id], entry.store === store { return entry.presenter }
        let presenter = TranscriptGalleryPresenter()
        galleryPresenters[store.id] = (store, presenter)
        return presenter
    }

    private func resetReaderScopeIfNeeded(for store: ChannelStore) {
        if artifactSessions[store.id].map({ $0.store !== store }) == true
            || galleryPresenters[store.id].map({ $0.store !== store }) == true {
            closeReaders(for: store.id)
            artifactSessions[store.id] = nil
            galleryPresenters[store.id] = nil
        }
    }

    private func closeReaders(for channelID: String) {
        artifactSessions[channelID]?.session.close()
        galleryPresenters[channelID]?.presenter.close()
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

struct BrowserFailure {
    let url: URL?
    let message: String
}

enum ServerSwitchFailure: LocalizedError {
    case changed

    var errorDescription: String? {
        "The connected server changed while confirmation was open. Review the server address and try again."
    }
}
