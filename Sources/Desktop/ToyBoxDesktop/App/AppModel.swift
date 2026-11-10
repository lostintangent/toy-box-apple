import AppKit
import ChannelClient
import ChannelIntelligence
import ChannelKit
import Foundation
import Observation
import SwiftUI
import ToyBoxUI

enum AppConfiguration {
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
    let openAtLogin: OpenAtLogin
    let quickSend: QuickSendController
    let widgetSnapshots: WidgetSnapshotPublisher
    private let dockAttention: DockAttention
    /// Every server in Settings order, each with its own catalog stream and channel stores.
    private(set) var catalogs: [ChannelCatalogStore] = []
    /// The first server, which the windows and integrations show until they span every server.
    var catalog: ChannelCatalogStore? { catalogs.first }
    /// The first server's address, or a launch address that isn't usable.
    private(set) var serverURL: String
    /// Every message the user sends until its server confirms it. Each server's catalog delivers its own.
    let outbox: ChannelOutbox
    /// Why a launch address isn't usable, which leaves no server at all.
    private(set) var configurationError: String?
    private(set) var openChannelIDs: Set<String> = []
    private(set) var activeChannelID: String?
    let notifications = ChannelNotifications()
    private(set) var morningDigest: MorningDigest?
    let folders = ChannelFolders()
    /// Retry or View > Refresh is in flight, which spins the sidebar footer. Polls never do.
    private(set) var isRefreshingCatalog = false
    let menuBar = MenuBarPresence()
    var navigationRequest: ChannelNavigationRequest?
    var newChannelRequest: UUID?
    @ObservationIgnored var openChannelWindow: ((String) -> Void)?
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var unhideObserver: NSObjectProtocol?
    @ObservationIgnored let connections = ChannelConnections()
    @ObservationIgnored private let launchChannel = LaunchChannel()
    @ObservationIgnored private var launchChannelID: String?
    @ObservationIgnored private var windows: [UUID: String] = [:]
    @ObservationIgnored private var keyWindowID: UUID?
    /// What each channel window shows Siri.
    @ObservationIgnored private var screens: [UUID: ChannelIntents.Screen] = [:]
    @ObservationIgnored private var dockBadgeLabel: String?
    @ObservationIgnored private var catalogGeneration = UUID()
    @ObservationIgnored private var applicationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var composerSessions: [String: ChannelComposerSession] = [:]
    /// A launch override, snapshot or benchmark keeps its server to the session, so Settings never
    /// saves over the user's servers.
    @ObservationIgnored private let savesServers: Bool

    init(launchOptions: LaunchOptions = .init()) {
        self.launchOptions = launchOptions
        updates = AppUpdates(isSnapshot: launchOptions.isSnapshot)
        // A snapshot never sends, so it leaves the user's saved messages alone.
        outbox = ChannelOutbox(folder: launchOptions.isSnapshot
            ? .temporaryDirectory.appending(path: "ToyBoxSnapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
            : ChannelOutbox.defaultFolder)
        openAtLogin = OpenAtLogin(isAvailable: OpenAtLogin.isAllowed(
            launchOptions, bundleID: Bundle.main.bundleIdentifier))
        quickSend = QuickSendController(options: launchOptions)
        widgetSnapshots = WidgetSnapshotPublisher(enabled: launchOptions.allowsUserIntegrations())
        dockAttention = DockAttention(
            allowed: DockAttention.isAllowed(launchOptions, bundleID: Bundle.main.bundleIdentifier),
            enabled: { UserDefaults.standard.bool(forKey: DockAttention.enabledKey) },
            active: { NSApplication.shared.isActive },
            request: { _ = NSApplication.shared.requestUserAttention($0) }
        )
        snapshot = launchOptions.isSnapshot ? WindowSnapshot(options: launchOptions) : nil
        resizeBenchmark = launchOptions.resizeBenchmark.flatMap { mode in
            launchOptions.channelID.map { ResizeBenchmark(mode: mode, channelID: $0) }
        }
        performanceBenchmark = launchOptions.benchmark.flatMap { scenario in
            launchOptions.channelID.map { PerformanceBenchmark(scenario: scenario, channelID: $0) }
        }
        savesServers = launchOptions.allowsUserIntegrations()
        let saved = savesServers ? ChannelCatalogStore.Saved.load(from: .standard) : []
        serverURL = launchOptions.serverURL ?? saved.first?.url ?? AppConfiguration.defaultServerURL
        var failure: (any Error)?
        catalogs = (saved.isEmpty ? [.init(url: serverURL)] : saved).compactMap { server in
            do { return try connect(ChannelAPI(serverURL: server.url), name: server.name) }
            catch { failure = error; return nil }
        }
        if catalogs.isEmpty { configurationError = failure?.localizedDescription }
        firstServerDidChange()
        if !launchOptions.isSnapshot { launchChannelID = launchChannel.channelID(serverURL: self.serverURL) }
        notifications.onActivate = { [weak self] activation in
            guard let self, self.serverURL == activation.serverURL else { return }
            self.activate(channelID: activation.channel.channelID, sequence: activation.channel.sequence)
        }
        notifications.send = { [weak self] reply in
            await self?.outbox.send(reply.content, to: reply.channelID, on: reply.server, answering: reply.request)
        }
        notifications.resolveRequest = { [weak self] channel, sequence in
            self?.catalog?.waitingRequests().first { $0.channel.id == channel.id && $0.sequence == sequence }?.request
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            applicationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    for catalog in self?.catalogs ?? [] { catalog.setActive(NSApplication.shared.isActive) }
                    if NSApplication.shared.isActive { self?.refreshFolders() }
                    await self?.notifications.refreshAuthorization()
                }
            })
        }
        if showsMenuBarExtra { observeMenuBarActivity() }
        morningDigest = MorningDigest(host: .init(
            server: { [weak self] in self?.serverURL ?? "" },
            authorized: { [weak self] in
                guard let notifications = self?.notifications else { return false }
                await notifications.refreshAuthorization()
                return notifications.authorization == .authorized || notifications.authorization == .provisional
            },
            build: { [weak self] window in
                guard let api = self?.api else { throw ChannelAPIError.invalidServerURL }
                return try await MorningDigest.build(
                    api: api, window: window,
                    summarizes: IntelligenceSettings.isOn(IntelligenceSettings.summarizesNewMessages),
                    intelligence: LiveChannelIntelligence.shared
                )
            },
            deliver: { [weak self] content, server, identifier in
                guard let notifications = self?.notifications else { throw ChannelAPIError.disconnected }
                try await notifications.deliverMorningDigest(content, serverURL: server, identifier: identifier)
            }
        ), allowed: MorningDigest.isAllowed(launchOptions, bundleID: Bundle.main.bundleIdentifier),
           testAllowed: MorningDigest.canTest(bundleID: Bundle.main.bundleIdentifier,
                                              options: launchOptions, server: serverURL))
        morningDigest?.start()
    }

    isolated deinit {
        for token in applicationObservers { NotificationCenter.default.removeObserver(token) }
    }

    var api: ChannelAPI? { catalog?.api }

    func composerSession(for store: ChannelStore, draft: ComposerDraft) -> ChannelComposerSession {
        if let session = composerSessions[store.id], session.store === store, session.draft === draft {
            return session
        }
        let session = ChannelComposerSession(store: store, draft: draft)
        composerSessions[store.id] = session
        return session
    }

    var lastUsedChannelID: String? {
        activeChannelID ?? launchChannel.channelID(serverURL: serverURL)
    }

    // MARK: Servers

    /// Adds a server, or finds the one already at that address, for Settings to select.
    func addServer(_ address: String) throws -> ChannelCatalogStore {
        let api = try ChannelAPI(serverURL: address)
        if let listed = catalogs.first(at: api.baseURL.absoluteString) { return listed }
        let catalog = connect(api, name: nil)
        configurationError = nil
        updateServers { $0.append(catalog) }
        return catalog
    }

    /// Replaces a server's live connections with another address, or finds the server already
    /// there, for Settings to select. Drafts stay with the old address.
    func changeAddress(of catalog: ChannelCatalogStore, to address: String) throws -> ChannelCatalogStore {
        let api = try ChannelAPI(serverURL: address)
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
        catalog.setActive(NSApplication.shared.isActive)
        catalog.startPolling()
        return catalog
    }

    private func disconnect(_ catalog: ChannelCatalogStore) {
        catalog.stopPolling()
        catalog.outbox = nil
        connections.disconnectAll(in: catalog)
        composerSessions = composerSessions.filter { $0.value.store.api.baseURL != catalog.api.baseURL }
    }

    private func updateServers(_ change: (inout [ChannelCatalogStore]) -> Void) {
        let first = catalog
        change(&catalogs)
        if savesServers { ChannelCatalogStore.Saved.save(catalogs.map(\.saved), to: .standard) }
        if catalog !== first { firstServerDidChange() }
    }

    /// Everything outside Settings shows the first server, so a new first server starts it over.
    private func firstServerDidChange() {
        if let address = catalog?.api.baseURL.absoluteString, address != serverURL {
            quickSend.dismiss()
            serverURL = address
        }
        isRefreshingCatalog = false
        notifications.reset()
        dockAttention.reset()
        catalogGeneration = UUID()
        observeCatalog(generation: catalogGeneration)
        widgetSnapshots.update(status: menuBarStatus, serverURL: serverURL, hasCatalog: false)
    }

    /// Connects a store for a window, sheet or intent that shows it. Pair each with a release.
    func hold(_ store: ChannelStore) { connections.hold(store) }

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
        screens[id] = nil
        guard windows.removeValue(forKey: id) != nil || keyWindowID == id else { return }
        if keyWindowID == id { keyWindowID = nil }
        windowsDidChange()
    }

    /// Records what a window shows Siri, or that it shows nothing Siri may read.
    func updateScreen(_ id: UUID, _ screen: ChannelIntents.Screen?) {
        screens[id] = screen
    }

    /// The channel or artifact Siri may read: what the frontmost of the app's windows shows, while
    /// you can see it. The app needn't be active, since Siri's own panel may take that from it, as
    /// its overlay does on the phone. A sheet keeps its window's conversation in view, but any other
    /// window in front, like Settings, shows Siri nothing.
    var onScreen: ChannelIntents.OnScreen? {
        let app = NSApplication.shared
        guard !app.isHidden,
              let front = app.orderedWindows.first(where: { $0.isVisible && $0.sheetParent == nil }) else { return nil }
        guard !front.isMiniaturized, front.occlusionState.contains(.visible) else { return nil }
        return ChannelIntents.Screen.onScreen(in: front, screens: screens.values, catalog: catalog)
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
    }

    /// Brings a channel forward from outside its windows, as notifications and the menu bar do. The
    /// frontmost window selects it, or a new window opens on it when there is none. Without a
    /// channel, the frontmost window just comes forward.
    func activate(channelID: String?, sequence: Int? = nil) {
        if let channelID {
            navigationRequest = .init(channelID: channelID, sequence: sequence)
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

    /// What the menu bar extra shows, from the same waiting requests and working agents as the sidebar.
    var menuBarStatus: MenuBarStatus {
        let unreachable = configurationError != nil || catalog?.phase.message != nil
            ? SidebarFooter.server(serverURL) : nil
        guard let catalog, catalog.state != nil else {
            return MenuBarStatus(unreachableHost: unreachable)
        }
        let presentation = sidebarPresentation
        return MenuBarStatus(requests: catalog.waitingRequests(openChannelIDs: openChannelIDs), catalog.channels.map {
            .init(channel: presentation.channel($0), working: presentation.working($0, agents: presentation.agents($0)))
        }, unreachableHost: unreachable)
    }

    /// Keeps the status item in step with activity, including an open channel's live presence.
    private func observeMenuBarActivity() {
        let (status, hasCatalog) = withObservationTracking {
            _ = catalog?.lastRefreshedAt
            return (menuBarStatus, catalog?.isLoaded == true)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMenuBarActivity() }
        }
        menuBar.update(isActive: status.isActive)
        widgetSnapshots.update(status: status, serverURL: serverURL, hasCatalog: catalog?.state != nil)
        dockAttention.update(status: status, serverURL: serverURL, hasCatalog: hasCatalog)
    }

    private var sidebarPresentation: ChannelSidebarPresentation {
        .init(catalog: catalog, openChannelIDs: openChannelIDs)
    }

    func sidebarChannel(_ channel: Channel) -> Channel {
        sidebarPresentation.channel(channel)
    }

    func sidebarAttention(_ channel: Channel) -> Channel.Attention? {
        sidebarPresentation.attention(channel)
    }

    func sidebarAgents(_ channel: Channel) -> [ChannelAgent] {
        sidebarPresentation.agents(channel)
    }

    func sidebarWorking(_ channel: Channel, agents: [ChannelAgent]) -> [ChannelAgent] {
        sidebarPresentation.working(channel, agents: agents)
    }

    static func dockBadge(channels: [Channel], openChannelIDs: Set<String>) -> String? {
        let count = channels.filter {
            $0.sidebarAttention(isOpen: openChannelIDs.contains($0.id)) != nil
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
        isRefreshingCatalog = true
        Task {
            await catalog.refresh()
            if self.catalog === catalog { isRefreshingCatalog = false }
        }
    }

    func openInToyBox(channelID: String) {
        guard let url = channelURL(channelID: channelID) else { return }
        NSWorkspace.shared.open(url)
    }

    func channelURL(channelID: String, files: [WorkspaceFile] = []) -> URL? {
        api?.channelURL(channelID: channelID, files: files)
    }
}

struct ChannelNavigationRequest: Identifiable {
    let id = UUID()
    let channelID: String
    let sequence: Int?
}
