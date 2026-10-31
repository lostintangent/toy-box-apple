import AppKit
import ChannelClient
import ChannelIntelligence
import ChannelKit
import Foundation
import Observation
import ToyBoxUI

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
    let openAtLogin: OpenAtLogin
    let quickSend: QuickSendController
    let widgetSnapshots: WidgetSnapshotPublisher
    private let dockAttention: DockAttention
    private(set) var serverURL: String
    private(set) var catalog: ChannelCatalogStore?
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
    /// The waiting requests the menu bar, Dock, widget and notifications share.
    private(set) var waitingRequests: ChannelWaitingRequests?
    @ObservationIgnored var openChannelWindow: ((String) -> Void)?
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var unhideObserver: NSObjectProtocol?
    @ObservationIgnored let connections = ChannelConnections()
    @ObservationIgnored private let launchChannel = LaunchChannel()
    @ObservationIgnored private var launchChannelID: String?
    @ObservationIgnored private var windows: [UUID: String] = [:]
    @ObservationIgnored private var keyWindowID: UUID?
    @ObservationIgnored private var dockBadgeLabel: String?
    @ObservationIgnored private var catalogGeneration = UUID()
    @ObservationIgnored private var applicationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var composerSessions: [String: ChannelComposerSession] = [:]

    init(launchOptions: LaunchOptions = .init()) {
        self.launchOptions = launchOptions
        updates = AppUpdates(isSnapshot: launchOptions.isSnapshot)
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
        notifications.store = { [weak self] serverURL, channelID in
            guard let self, self.serverURL == serverURL else { return nil }
            return self.catalog?.channel(id: channelID)
        }
        notifications.resolveRequest = { [weak self] channel, sequence in
            try? await self?.waitingRequests?.message(channelID: channel.id, sequence: sequence)
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
                    summarizes: TranscriptIntelligenceSettings.isOn(TranscriptIntelligenceSettings.summarizesNewMessages),
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

    func configure(serverURL: String, persist: Bool = true) {
        do {
            let api = try ChannelAPI(serverURL: serverURL)
            if self.serverURL != api.baseURL.absoluteString { quickSend.dismiss() }
            catalog?.stopPolling()
            connections.disconnectAll()
            composerSessions = [:]
            self.serverURL = api.baseURL.absoluteString
            if persist, !launchOptions.isSnapshot {
                UserDefaults.standard.set(self.serverURL, forKey: AppConfiguration.serverURLKey)
            }
            let catalog = ChannelCatalogStore(api: api)
            self.catalog = catalog
            waitingRequests = ChannelWaitingRequests(catalog: catalog)
            isRefreshingCatalog = false
            configurationError = nil
            notifications.reset()
            dockAttention.reset()
            catalogGeneration = UUID()
            observeCatalog(generation: catalogGeneration)
            catalog.setActive(NSApplication.shared.isActive)
            catalog.startPolling()
            widgetSnapshots.update(status: menuBarStatus, serverURL: self.serverURL, hasCatalog: false)
        } catch {
            configurationError = error.localizedDescription
        }
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
        if showsMenuBarExtra { waitingRequests?.resolve(openChannelIDs: openChannelIDs) }
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

    /// What the menu bar extra shows, from the same waiting requests and working agents as the sidebar.
    var menuBarStatus: MenuBarStatus {
        let unreachable = configurationError != nil || catalog?.phase.message != nil
            ? SidebarFooter.server(serverURL) : nil
        guard let catalog, let waitingRequests, catalog.state != nil else {
            return MenuBarStatus(unreachableHost: unreachable)
        }
        let projection = sidebarProjection
        return MenuBarStatus(requests: waitingRequests.entries(openChannelIDs: openChannelIDs), catalog.channels.map {
            .init(channel: projection.channel($0), working: projection.working($0, agents: projection.agents($0)))
        }, unreachableHost: unreachable)
    }

    func retryMenuBarRequest(channelID: String) {
        waitingRequests?.retry(channelID: channelID, openChannelIDs: openChannelIDs)
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

    private var sidebarProjection: ChannelSidebarProjection {
        .init(catalog: catalog, openChannelIDs: openChannelIDs)
    }

    func sidebarChannel(_ channel: Channel) -> Channel {
        sidebarProjection.channel(channel)
    }

    func sidebarAttention(_ channel: Channel) -> ChannelAttention? {
        sidebarProjection.attention(channel)
    }

    func sidebarAgents(_ channel: Channel) -> [ChannelAgent] {
        sidebarProjection.agents(channel)
    }

    func sidebarWorking(_ channel: Channel, agents: [ChannelAgent]) -> [ChannelAgent] {
        sidebarProjection.working(channel, agents: agents)
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
    /// Set when a reply from a notification wasn't sent and waits in the composer.
    var focusComposer = false
}
