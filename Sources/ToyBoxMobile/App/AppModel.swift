import ChannelClient
import ChannelKit
import Foundation
import Observation
import ToyBoxUI
import UIKit

@MainActor @Observable
final class AppModel {
    private(set) var serverURL = ""
    private(set) var catalog: ChannelCatalogStore?
    private(set) var configurationError: String?
    private(set) var isActive = false
    private(set) var selectedStore: ChannelStore?
    var visibleChannelID: String?
    var isSettingsPresented = false
    var navigationNotice: String?
    var browserFailure: BrowserFailure?
    let requestedRefresh = RequestedCatalogRefresh()
    var selectedChannelID: String? {
        didSet {
            guard oldValue != selectedChannelID else { return }
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
    @ObservationIgnored private var serverIdentity = ""
    @ObservationIgnored private var interactions: [String: ChannelInteraction] = [:]
    @ObservationIgnored private var composerSessions: [String: ComposerSession] = [:]
    @ObservationIgnored private var artifactSessions: [String: (store: ChannelStore, session: ChannelArtifactSession)] = [:]
    @ObservationIgnored private var galleryPresenters: [String: (store: ChannelStore, presenter: TranscriptGalleryPresenter)] = [:]

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        let address: String?
        if let index = arguments.firstIndex(of: "--server") {
            guard arguments.indices.contains(index + 1) else {
                configurationError = "Provide a server URL after --server."
                return
            }
            address = arguments[index + 1]
        } else {
            address = environment["TOY_BOX_SERVER_URL"] ?? defaults.string(forKey: "serverURL")
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

    var canCreateChannel: Bool { isActive && sidebarConnection == .connected }

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
        configurationError = nil
        navigationNotice = nil
        browserFailure = nil
        restoredSelection = false
        if persist { defaults.set(self.serverURL, forKey: "serverURL") }
        if isActive { catalog?.startPolling() }
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
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
        guard !restoredSelection, let catalog, catalog.hasLoaded else { return }
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
