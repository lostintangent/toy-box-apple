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
    let performanceBenchmark: PerformanceBenchmark?
    let updates: AppUpdates
    let quickAsk: QuickAskController
    private(set) var serverURL: String
    private(set) var catalog: ChannelCatalogStore?
    private(set) var configurationError: String?
    private(set) var openChannelIDs: Set<String> = []
    private(set) var activeChannelID: String?
    let notifications = ChannelNotifications()
    let folders = ChannelFolders()
    let requestedRefresh = RequestedCatalogRefresh()
    let menuBar = MenuBarPresence()
    var navigationRequest: ChannelNavigationRequest?
    var newChannelRequest: UUID?
    /// Pending requests' messages for the menu bar, by channel.
    private(set) var menuBarRequests: [String: ChannelNotifications.ResolvedRequest] = [:]
    @ObservationIgnored var openChannelWindow: ((String) -> Void)?
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var menuBarLookups: [String: Int] = [:]
    @ObservationIgnored private var unhideObserver: NSObjectProtocol?
    @ObservationIgnored let connections = ChannelConnections<ChannelStore>()
    @ObservationIgnored private let launchChannel = LaunchChannel()
    @ObservationIgnored private var launchChannelID: String?
    @ObservationIgnored private var windows: [UUID: String] = [:]
    @ObservationIgnored private var keyWindowID: UUID?
    @ObservationIgnored private var dockBadgeLabel: String?
    @ObservationIgnored private var catalogGeneration = UUID()
    @ObservationIgnored private var applicationObservers: [NSObjectProtocol] = []

    init(launchOptions: LaunchOptions = .init()) {
        self.launchOptions = launchOptions
        updates = AppUpdates(isSnapshot: launchOptions.isSnapshot)
        quickAsk = QuickAskController(options: launchOptions)
        snapshot = launchOptions.isSnapshot ? WindowSnapshot(options: launchOptions) : nil
        resizeBenchmark = launchOptions.resizeBenchmark.flatMap { mode in
            launchOptions.channelID.map { ResizeBenchmark(mode: mode, channelID: $0) }
        }
        performanceBenchmark = launchOptions.benchmark.flatMap { scenario in
            launchOptions.channelID.map { PerformanceBenchmark(scenario: scenario, channelID: $0) }
        }
        serverURL = launchOptions.serverURL ?? ProcessInfo.processInfo.environment["TOY_BOX_SERVER_URL"]
            ?? UserDefaults.standard.string(forKey: AppConfiguration.serverURLKey)
            ?? AppConfiguration.defaultServerURL
        configure(serverURL: serverURL, persist: false)
        if !launchOptions.isSnapshot { launchChannelID = launchChannel.channelID(serverURL: self.serverURL) }
        notifications.onActivate = { [weak self] activation in
            guard let self, self.serverURL == activation.serverURL else { return }
            self.activate(channelID: activation.channelID, sequence: activation.sequence,
                          focusComposer: activation.focusComposer)
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
        if showsMenuBarExtra { observeMenuBarActivity() }
    }

    isolated deinit {
        for token in applicationObservers { NotificationCenter.default.removeObserver(token) }
    }

    func authorizeImportedNotificationsIfNeeded() async {
        guard AppPreferencesMigration.takeNotificationOptIn(isSnapshot: launchOptions.isSnapshot) else { return }
        await notifications.refreshAuthorization()
        if notifications.authorization == .notDetermined {
            if !(await notifications.enable()) {
                UserDefaults.standard.set(false, forKey: "notificationsEnabled")
            }
        } else if notifications.authorization == .denied {
            UserDefaults.standard.set(false, forKey: "notificationsEnabled")
        }
    }

    var api: ChannelAPI? { catalog?.api }

    func configure(serverURL: String, persist: Bool = true) {
        do {
            let api = try ChannelAPI(serverURL: serverURL)
            catalog?.stopPolling()
            connections.disconnectAll()
            self.serverURL = api.baseURL.absoluteString
            if persist, !launchOptions.isSnapshot {
                UserDefaults.standard.set(self.serverURL, forKey: AppConfiguration.serverURLKey)
            }
            catalog = ChannelCatalogStore(api: api)
            configurationError = nil
            notifications.reset()
            menuBarRequests = [:]
            menuBarLookups = [:]
            catalogGeneration = UUID()
            observeCatalog(generation: catalogGeneration)
            catalog?.setActive(NSApplication.shared.isActive)
            catalog?.startPolling()
        } catch {
            configurationError = error.localizedDescription
        }
    }

    /// Connects a store for a window, sheet or intent that shows it. Pair each with a release.
    func acquire(_ store: ChannelStore) { connections.acquire(store) }

    /// The last release keeps the store connected for a few seconds, so switching back is live at once.
    func release(_ store: ChannelStore) { connections.release(store) }

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
        if active != activeChannelID {
            activeChannelID = active
            if let active, !launchOptions.isSnapshot { launchChannel.remember(active, serverURL: serverURL) }
        }
        catalogDidChange()
    }

    // MARK: Launch

    /// The channel you were last in on this server, for the first window to appear. Only that
    /// window takes it, so File > New Window still opens without a channel. Launch doesn't connect
    /// it early: the snapshot already arrives while the window is built, and a channel that's
    /// loaded first holds the window back until its whole transcript renders.
    func takeLaunchChannelID() -> String? {
        defer { launchChannelID = nil }
        return launchChannelID
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
        resolveMenuBarRequests()
    }

    /// Brings a channel forward from outside its windows, as notifications and the menu bar do. The
    /// frontmost window selects it, or a new window opens on it when there is none. Without a
    /// channel, the frontmost window just comes forward.
    func activate(channelID: String?, sequence: Int? = nil, focusComposer: Bool = false) {
        if let channelID {
            navigationRequest = .init(channelID: channelID, sequence: sequence, focusComposer: focusComposer)
        }
        let app = NSApplication.shared
        guard app.isHidden else {
            app.activate()
            return bringForward(channelID)
        }
        // Unhiding finishes on a later turn, and until then every window reads as invisible, so
        // looking now would open a second window beside the one coming back.
        if let unhideObserver { NotificationCenter.default.removeObserver(unhideObserver) }
        unhideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUnhideNotification, object: app, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didUnhide(channelID) }
        }
        app.activate()
        app.unhide(nil)
    }

    private func didUnhide(_ channelID: String?) {
        if let unhideObserver { NotificationCenter.default.removeObserver(unhideObserver) }
        unhideObserver = nil
        bringForward(channelID)
    }

    private func bringForward(_ channelID: String?) {
        if let window = Self.frontChannelWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let channelID {
            openChannelWindow?(channelID)
        } else {
            openMainWindow?()
        }
    }

    private static func frontChannelWindow() -> NSWindow? {
        func isChannelWindow(_ window: NSWindow) -> Bool {
            window.identifier?.rawValue.hasPrefix("channels") == true && window.canBecomeMain
        }
        let app = NSApplication.shared
        return app.orderedWindows.first { isChannelWindow($0) && $0.isVisible }
            ?? app.windows.first { isChannelWindow($0) && $0.isMiniaturized }
    }

    // MARK: Menu bar extra

    /// Captures, snapshots and benchmarks keep the menu bar out of what they measure.
    var showsMenuBarExtra: Bool {
        !launchOptions.isSnapshot && resizeBenchmark == nil && performanceBenchmark == nil
    }

    /// What the menu bar extra shows, from the same attention and working agents as the sidebar.
    var menuBarStatus: MenuBarStatus {
        let unreachable = configurationError != nil || catalog?.error != nil
            ? SidebarConnection.server(serverURL) : nil
        guard let catalog, catalog.state != nil else { return MenuBarStatus(unreachableHost: unreachable) }
        let inputs = catalog.channels.map { channel in
            let current = sidebarChannel(channel)
            let isWaiting = sidebarAttention(channel) == .waiting
            return MenuBarStatus.Input(channel: current, isWaiting: isWaiting,
                                       working: sidebarWorking(channel, agents: sidebarAgents(channel)),
                                       request: isWaiting ? menuBarRequest(current) : nil)
        }
        return MenuBarStatus(inputs, unreachableHost: unreachable)
    }

    /// An open channel's live request, otherwise the one looked up for its sequence.
    private func menuBarRequest(_ channel: Channel) -> ChannelNotifications.ResolvedRequest? {
        guard let sequence = channel.requestSequence else { return nil }
        if openChannelIDs.contains(channel.id), let store = catalog?.channel(id: channel.id),
           let request = store.request, request.sequence == sequence {
            return .init(message: request, agents: store.roster)
        }
        return menuBarRequests[channel.id].flatMap { $0.message.sequence == sequence ? $0 : nil }
    }

    /// Looks up each new request's message once, so the menu can quote it before it opens.
    private func resolveMenuBarRequests() {
        guard let catalog, showsMenuBarExtra,
              MenuBarVisibility(rawValue: UserDefaults.standard.string(forKey: MenuBarVisibility.key) ?? "") != .never
        else { return }
        let pending = Dictionary(catalog.channels.compactMap { channel in channel.requestSequence.map { (channel.id, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        let kept = menuBarRequests.filter { pending[$0.key] == $0.value.message.sequence }
        if kept.count != menuBarRequests.count { menuBarRequests = kept }
        let generation = catalogGeneration
        for channel in catalog.channels {
            guard let sequence = pending[channel.id], kept[channel.id] == nil,
                  menuBarLookups[channel.id] != sequence else { continue }
            menuBarLookups[channel.id] = sequence
            Task {
                let resolved = await resolveRequest(channel: channel, sequence: sequence)
                guard generation == catalogGeneration, menuBarLookups[channel.id] == sequence else { return }
                // A failed lookup tries again on a later poll.
                menuBarLookups[channel.id] = nil
                if let resolved, self.catalog?.channels.first(where: { $0.id == channel.id })?.requestSequence == sequence {
                    menuBarRequests[channel.id] = resolved
                }
            }
        }
    }

    /// Keeps the status item in step with activity, including an open channel's live presence.
    private func observeMenuBarActivity() {
        let isActive = withObservationTracking { menuBarStatus.isActive } onChange: { [weak self] in
            Task { @MainActor in self?.observeMenuBarActivity() }
        }
        menuBar.update(isActive: isActive)
    }

    /// A channel as the sidebar shows it: an open channel's live details and request over its catalog
    /// entry. It reads only those slices, so the store's other events leave the sidebar and the title
    /// menu alone. Activity times follow the catalog, and an open channel shows only its request.
    func sidebarChannel(_ channel: Channel) -> Channel {
        guard openChannelIDs.contains(channel.id), let store = catalog?.channel(id: channel.id),
              let details = store.details else { return channel }
        var live = channel
        live.name = details.name
        live.purpose = details.purpose
        live.directory = details.directory
        live.model = details.model
        live.preview = details.preview
        live.previewUrl = details.previewUrl
        live.requestSequence = store.requestSequence
        return live
    }

    /// The attention the sidebar shows for a channel. The title menu and the menu bar mirror it.
    func sidebarAttention(_ channel: Channel) -> ChannelAttention? {
        channelSidebarStatus(sidebarChannel(channel), isOpen: openChannelIDs.contains(channel.id))
    }

    /// A channel's agents as its sidebar row shows them: an open channel's loaded roster, otherwise
    /// the catalog's.
    func sidebarAgents(_ channel: Channel) -> [ChannelAgent] {
        if openChannelIDs.contains(channel.id), let store = catalog?.channel(id: channel.id), store.isLoaded {
            return store.roster
        }
        return catalogAgents(channelID: channel.id)
    }

    /// Who's working in a channel: live presence for an open channel, otherwise the catalog's
    /// `working`. The sidebar row and the menu bar both ask this one function.
    func sidebarWorking(_ channel: Channel, agents: [ChannelAgent]) -> [ChannelAgent] {
        if openChannelIDs.contains(channel.id), let store = catalog?.channel(id: channel.id) {
            return store.phase.isLive ? agents.filter { store.presence[$0.id]?.state == "working" } : []
        }
        guard let catalog, catalog.error == nil else { return [] }
        return agents.filter { catalog.working.contains($0.id) }
    }

    /// A channel's agents as the catalog knows them, for channels that aren't open.
    func catalogAgents(channelID: String) -> [ChannelAgent] {
        guard let catalog, let lead = catalog.state?.lead else { return [] }
        return [ChannelAgent.lead(id: channelID, profile: lead)] + catalog.members.filter { $0.channelId == channelID }
    }

    /// A request's message, from an open channel's live state, otherwise from its history.
    private func resolveRequest(channel: Channel, sequence: Int) async -> ChannelNotifications.ResolvedRequest? {
        if let known = menuBarRequests[channel.id], known.message.sequence == sequence { return known }
        if let state = connections.stores.first(where: { $0.id == channel.id })?.state,
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
