import ChannelClient
import ChannelKit
import Foundation
import Observation
import ToyBoxUI

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
    var selectedChannelID: String? {
        didSet {
            guard oldValue != selectedChannelID else { return }
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
        catch { configurationError = error.localizedDescription }
    }

    var api: ChannelAPI? { catalog?.api }

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
        interactions = [:]
        composerSessions = [:]
        self.serverURL = api.baseURL.absoluteString
        serverIdentity = identity
        catalog = ChannelCatalogStore(api: api)
        configurationError = nil
        navigationNotice = nil
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
        await catalog?.refresh()
        reconcileSelection()
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
