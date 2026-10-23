import AppKit
import ChannelClient
import ChannelKit
import Foundation
import Observation

enum AppConfiguration {
    static let serverURLKey = "serverURL"
    static let defaultServerURL = ProcessInfo.processInfo.environment["TOY_BOX_SERVER_URL"]
        ?? "http://localhost:3000"
}

@MainActor @Observable
final class AppModel {
    let launchOptions: LaunchOptions
    let snapshot: WindowSnapshot?
    let resizeBenchmark: ResizeBenchmark?
    private(set) var serverURL: String
    private(set) var catalog: ChannelCatalogStore?
    private(set) var configurationError: String?
    private(set) var openChannelIDs: Set<String> = []
    private(set) var activeChannelID: String?
    let notifications = ChannelNotifications()
    let folders = ChannelFolders()
    let requestedRefresh = RequestedCatalogRefresh()
    var navigationRequest: ChannelNavigationRequest?
    var newChannelRequest: UUID?
    @ObservationIgnored var openChannelWindow: ((String) -> Void)?
    @ObservationIgnored private var connections: [ObjectIdentifier: (store: ChannelStore, count: Int)] = [:]
    @ObservationIgnored private var windows: [UUID: String] = [:]
    @ObservationIgnored private var keyWindowID: UUID?
    @ObservationIgnored private var dockBadgeLabel: String?
    @ObservationIgnored private var catalogGeneration = UUID()
    @ObservationIgnored private var applicationObservers: [NSObjectProtocol] = []

    init(launchOptions: LaunchOptions = .init()) {
        self.launchOptions = launchOptions
        snapshot = launchOptions.isSnapshot ? WindowSnapshot(options: launchOptions) : nil
        resizeBenchmark = launchOptions.resizeBenchmark.flatMap { mode in
            launchOptions.channelID.map { ResizeBenchmark(mode: mode, channelID: $0) }
        }
        serverURL = launchOptions.serverURL ?? ProcessInfo.processInfo.environment["TOY_BOX_SERVER_URL"]
            ?? UserDefaults.standard.string(forKey: AppConfiguration.serverURLKey)
            ?? AppConfiguration.defaultServerURL
        configure(serverURL: serverURL, persist: false)
        notifications.onActivate = { [weak self] activation in
            guard let self, self.serverURL == activation.serverURL else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.navigationRequest = .init(channelID: activation.channelID, sequence: activation.sequence,
                                           focusComposer: activation.focusComposer)
            if self.activeChannelID == nil { self.openChannelWindow?(activation.channelID) }
        }
        notifications.api = { [weak self] serverURL in
            guard let self, self.serverURL == serverURL else { return nil }
            return self.api
        }
        notifications.resolveRequest = { [weak self] channel, sequence in
            await self?.resolveRequest(channel: channel, sequence: sequence)
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            applicationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    self?.catalog?.setActive(NSApplication.shared.isActive)
                    if NSApplication.shared.isActive { self?.refreshFolders() }
                    await self?.notifications.refreshAuthorization()
                }
            })
        }
    }

    isolated deinit {
        for token in applicationObservers { NotificationCenter.default.removeObserver(token) }
    }

    var api: ChannelAPI? { catalog?.api }

    func configure(serverURL: String, persist: Bool = true) {
        do {
            let api = try ChannelAPI(serverURL: serverURL)
            catalog?.stopPolling()
            for connection in connections.values { connection.store.disconnect() }
            connections.removeAll()
            self.serverURL = api.baseURL.absoluteString
            if persist, !launchOptions.isSnapshot {
                UserDefaults.standard.set(self.serverURL, forKey: AppConfiguration.serverURLKey)
            }
            catalog = ChannelCatalogStore(api: api)
            configurationError = nil
            notifications.reset()
            catalogGeneration = UUID()
            observeCatalog(generation: catalogGeneration)
            catalog?.setActive(NSApplication.shared.isActive)
            catalog?.startPolling()
        } catch {
            configurationError = error.localizedDescription
        }
    }

    func acquire(_ store: ChannelStore) {
        let key = ObjectIdentifier(store)
        let count = connections[key]?.count ?? 0
        connections[key] = (store, count + 1)
        if count == 0 {
            store.captureUnreadBoundary()
            store.connect()
        }
    }

    func release(_ store: ChannelStore) {
        let key = ObjectIdentifier(store)
        guard let connection = connections[key] else { return }
        if connection.count == 1 {
            store.disconnect()
            connections.removeValue(forKey: key)
        } else {
            connections[key] = (store, connection.count - 1)
        }
    }

    /// Records a window's channel and whether it's key. Every sidebar row reads the open
    /// channels, so a window that reports without a change updates nothing.
    func updateWindow(_ id: UUID, channelID: String?, isKey: Bool) {
        let key = isKey ? id : keyWindowID == id ? nil : keyWindowID
        guard windows[id] != channelID || key != keyWindowID else { return }
        windows[id] = channelID
        keyWindowID = key
        windowsDidChange()
    }

    func removeWindow(_ id: UUID) {
        guard windows.removeValue(forKey: id) != nil || keyWindowID == id else { return }
        if keyWindowID == id { keyWindowID = nil }
        windowsDidChange()
    }

    private func windowsDidChange() {
        let open = Set(windows.values)
        if open != openChannelIDs { openChannelIDs = open }
        let active = keyWindowID.flatMap { windows[$0] }
        if active != activeChannelID { activeChannelID = active }
        catalogDidChange()
    }

    func catalogDidChange() {
        guard let catalog, !launchOptions.isSnapshot else { return }
        let badge = Self.dockBadge(channels: catalog.channels, openChannelIDs: openChannelIDs)
        if badge != dockBadgeLabel {
            dockBadgeLabel = badge
            NSApplication.shared.dockTile.badgeLabel = badge
        }
        if catalog.lastRefreshedAt != nil {
            notifications.update(channels: catalog.channels, activeChannelID: activeChannelID,
                                 serverURL: serverURL)
        }
    }

    /// A channel as the sidebar shows it: an open channel's live state, otherwise its catalog entry.
    func sidebarChannel(_ channel: Channel) -> Channel {
        guard openChannelIDs.contains(channel.id) else { return channel }
        return catalog?.channel(id: channel.id).state?.channel ?? channel
    }

    /// The attention the sidebar shows for a channel. The title menu mirrors it.
    func sidebarAttention(_ channel: Channel) -> ChannelAttention? {
        channelSidebarStatus(sidebarChannel(channel), isOpen: openChannelIDs.contains(channel.id))
    }

    /// A channel's agents as the catalog knows them, for channels that aren't open.
    func catalogAgents(channelID: String) -> [ChannelAgent] {
        guard let catalog, let lead = catalog.state?.lead else { return [] }
        return [ChannelAgent.lead(id: channelID, profile: lead)] + catalog.members.filter { $0.channelId == channelID }
    }

    /// A request's message, from an open channel's live state, otherwise from its history.
    private func resolveRequest(channel: Channel, sequence: Int) async -> ChannelNotifications.ResolvedRequest? {
        if let state = connections.values.first(where: { $0.store.id == channel.id })?.store.state,
           let message = state.request?.sequence == sequence ? state.request
               : state.messages.first(where: { $0.sequence == sequence }) {
            return .init(message: message, agents: state.agents)
        }
        guard let catalog else { return nil }
        let agents = catalogAgents(channelID: channel.id)
        guard let page = try? await catalog.api.history(channelId: channel.id, before: sequence + 1),
              let message = page.messages.first(where: { $0.sequence == sequence }) else { return nil }
        return .init(message: message, agents: agents)
    }

    static func dockBadge(channels: [Channel], openChannelIDs: Set<String>) -> String? {
        let count = channels.filter {
            channelSidebarStatus($0, isOpen: openChannelIDs.contains($0.id)) != nil
        }.count
        return count == 0 ? nil : String(count)
    }

    private func observeCatalog(generation: UUID) {
        guard generation == catalogGeneration, let catalog else { return }
        withObservationTracking {
            _ = catalog.channels
            _ = catalog.lastRefreshedAt
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.catalogGeneration else { return }
                self.refreshFolders()
                self.catalogDidChange()
                self.observeCatalog(generation: generation)
            }
        }
    }

    /// Cached, so it's safe to call from `body`. See `ChannelFolders`.
    func folderAvailability(path: String, server: URL) -> ChannelFolderAvailability {
        folders.availability(path: path, server: server)
    }

    private func refreshFolders() {
        guard let catalog else { return }
        folders.refresh(paths: catalog.channels.compactMap(\.directory), server: catalog.api.baseURL)
    }

    /// Retry and View > Refresh, the catalog refreshes someone asks for.
    func refreshCatalog() {
        guard let catalog else { return }
        Task { await requestedRefresh.run(catalog) }
    }

    func openInToyBox(channelID: String) {
        guard let url = channelURL(channelID: channelID) else { return }
        NSWorkspace.shared.open(url)
    }

    func channelURL(channelID: String, files: [WorkspaceFile] = []) -> URL? {
        guard let api, var components = URLComponents(url: api.baseURL, resolvingAgainstBaseURL: false),
              let data = try? JSONEncoder().encode([channelID]),
              let value = String(data: data, encoding: .utf8) else { return nil }
        components.queryItems = [URLQueryItem(name: "channels", value: value)]
        if !files.isEmpty {
            guard let data = try? JSONEncoder().encode(files),
                  let value = String(data: data, encoding: .utf8) else { return nil }
            components.queryItems?.append(URLQueryItem(name: "files", value: value))
        }
        return components.url
    }
}

struct ChannelNavigationRequest: Identifiable {
    let id = UUID()
    let channelID: String
    let sequence: Int?
    /// Set when a reply from a notification wasn't sent and waits in the composer.
    var focusComposer = false
}

/// The catalog refresh someone asked for, while it runs. The sidebar footer shows progress only for
/// these, never for background polling.
@MainActor @Observable
final class RequestedCatalogRefresh {
    private var catalog: ObjectIdentifier?

    func isRunning(for catalog: ChannelCatalogStore) -> Bool {
        self.catalog == ObjectIdentifier(catalog) && catalog.isLoading
    }

    /// Joins a refresh that is already in flight rather than starting a second one, so progress
    /// lasts until whichever attempt is running resolves.
    func run(_ catalog: ChannelCatalogStore) async {
        let id = ObjectIdentifier(catalog)
        self.catalog = id
        await catalog.refresh()
        while catalog.isLoading {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = catalog.isLoading } onChange: { continuation.resume() }
            }
        }
        if self.catalog == id { self.catalog = nil }
    }
}
