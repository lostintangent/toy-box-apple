import AppKit
import ChannelClient
import ChannelIntelligence
import ChannelKit
import Foundation
import Observation
import SwiftUI
import ToyBoxUI

@MainActor @Observable
final class AppModel {
    let launchOptions: LaunchOptions
    let snapshot: WindowSnapshot?
    let performanceBenchmark: PerformanceBenchmark?
    let updates: AppUpdates
    let openAtLogin: OpenAtLogin
    let quickSend: QuickSendController
    let widgetSnapshots: WidgetSnapshotPublisher
    private let dockAttention: DockAttention
    /// Every server opened this run, the one connected through first, each with its own catalog stream
    /// and channel stores.
    let servers: ChannelServers
    var catalogs: [ChannelCatalogStore] { servers.catalogs }
    /// The first server, which the windows and integrations show until they span every server.
    var catalog: ChannelCatalogStore? { catalogs.first }
    /// The first server's address, a launch address that isn't usable, or empty with no servers.
    private(set) var serverURL: String
    /// Every message the user sends until its server confirms it. Each server's catalog delivers its own.
    let outbox: ChannelOutbox
    /// Why a launch address isn't usable, which leaves no server at all.
    private(set) var configurationError: String?
    /// The channel each window shows, on its server.
    private(set) var openChannels: Set<ChannelTarget> = []
    /// The key window's channel.
    private(set) var activeChannel: ChannelTarget?
    let notifications = ChannelNotifications()
    private(set) var morningDigest: MorningDigest?
    let folders = ChannelFolders()
    /// The catalogs a Retry or View > Refresh is refreshing, which spins their status dots. Polls never do.
    private var refreshing: Set<ObjectIdentifier> = []
    let menuBar = MenuBarPresence()
    var navigationRequest: ChannelNavigationRequest?
    /// The tab Settings shows, which anything about the server sets to Servers before opening it.
    var settingsTab = SettingsTab.general
    var newChannelRequest: UUID?
    @ObservationIgnored var openChannelWindow: ((ChannelTarget) -> Void)?
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var unhideObserver: NSObjectProtocol?
    @ObservationIgnored let connections = ChannelConnections()
    @ObservationIgnored private let launchChannel = LaunchChannel()
    @ObservationIgnored private var launchChannelID: String?
    /// The channel `--channel` names, on the first server in Settings order whose catalog lists it,
    /// like any reference that doesn't name its server. It resolves to nil once every server has
    /// answered without it.
    @ObservationIgnored private(set) var launchTarget: Task<ChannelTarget?, Never>?
    @ObservationIgnored private var windows: [UUID: ChannelTarget] = [:]
    @ObservationIgnored private var keyWindowID: UUID?
    /// What each channel window shows Siri.
    @ObservationIgnored private var screens: [UUID: ChannelIntents.Screen] = [:]
    @ObservationIgnored private var dockBadgeLabel: String?
    @ObservationIgnored private var catalogGeneration = UUID()
    @ObservationIgnored private var applicationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var composerSessions: [String: ChannelComposerSession] = [:]

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
        performanceBenchmark = launchOptions.benchmark.flatMap { scenario in
            launchOptions.channelID.map { PerformanceBenchmark(scenario: scenario, channelID: $0) }
        }
        // A launch override, snapshot or benchmark keeps its server to the session, so Settings never
        // saves over the user's servers. The app starts with no server the user didn't add.
        let savesServers = launchOptions.allowsUserIntegrations()
        let address = savesServers ? ChannelServers.saved(in: .standard) : launchOptions.sessionServer()
        serverURL = address ?? ""
        servers = ChannelServers(address, savingTo: savesServers ? .standard : nil, outbox: outbox,
                                 connections: connections, isActive: NSApplication.shared.isActive,
                                 streamsInBackground: true)
        if servers.catalogs.isEmpty, let address {
            do { _ = try ChannelAPI(serverURL: address) }
            catch { configurationError = error.localizedDescription }
        }
        servers.onChange = { [weak self] in
            self?.configurationError = nil
            self?.serversDidChange()
        }
        servers.onRemove = { [weak self] catalog in
            guard let self else { return }
            composerSessions = composerSessions.filter { $0.value.store.api.baseURL != catalog.api.baseURL }
            notifications.forget(catalog.api.baseURL.absoluteString)
        }
        serversDidChange()
        if !launchOptions.isSnapshot { launchChannelID = launchChannel.channelID(serverURL: self.serverURL) }
        launchTarget = launchOptions.channelID.map { id in
            let catalogs = catalogs
            return Task { await catalogs.first(listing: id)?.target(id) }
        }
        notifications.onActivate = { [weak self] activation in
            self?.activate(ChannelTarget(serverURL: activation.serverURL, channelID: activation.channel.channelID),
                           sequence: activation.channel.sequence)
        }
        notifications.send = { [weak self] reply in
            await self?.outbox.send(reply.content, to: reply.channelID, on: reply.server, answering: reply.request)
        }
        notifications.resolveRequest = { [weak self] channel, sequence, server in
            self?.catalogs.first(at: server)?.waitingRequests()
                .first { $0.channel.id == channel.id && $0.sequence == sequence }?.request
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            applicationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    self?.servers.isActive = NSApplication.shared.isActive
                    if NSApplication.shared.isActive { self?.refreshFolders() }
                    await self?.notifications.refreshAuthorization()
                }
            })
        }
        if showsMenuBarExtra { observeMenuBarActivity() }
        morningDigest = MorningDigest(host: .init(
            servers: { [weak self] in self?.catalogs.map(\.api.baseURL.absoluteString) ?? [] },
            authorized: { [weak self] in
                guard let notifications = self?.notifications else { return false }
                await notifications.refreshAuthorization()
                return notifications.authorization == .authorized || notifications.authorization == .provisional
            },
            build: { [weak self] server, window in
                guard let api = self?.catalogs.first(at: server)?.api else { throw ChannelAPIError.disconnected }
                return try await MorningDigest.build(
                    api: api, window: window,
                    summarizes: IntelligenceSettings.isOn(IntelligenceSettings.summarizesNewMessages),
                    intelligence: LiveChannelIntelligence.shared
                )
            },
            deliver: { [weak self] content, identifier in
                guard let notifications = self?.notifications else { throw ChannelAPIError.disconnected }
                try await notifications.deliverMorningDigest(content, identifier: identifier)
            }
        ), allowed: MorningDigest.isAllowed(launchOptions, bundleID: Bundle.main.bundleIdentifier),
           testAllowed: catalogs.contains { MorningDigest.canTest(bundleID: Bundle.main.bundleIdentifier,
                                                                  options: launchOptions,
                                                                  server: $0.api.baseURL.absoluteString) })
        morningDigest?.start()
    }

    isolated deinit {
        for token in applicationObservers { NotificationCenter.default.removeObserver(token) }
    }

    var api: ChannelAPI? { catalog?.api }

    func openChannelIDs(on catalog: ChannelCatalogStore?) -> Set<String> {
        let server = Self.address(of: catalog)
        return Set(openChannels.compactMap { $0.serverURL == server ? $0.channelID : nil })
    }

    /// A channel on its server, or on the first server for a reference that doesn't name one.
    func target(_ channelID: String, on server: String? = nil) -> ChannelTarget? {
        ChannelTarget(serverURL: server ?? serverURL, channelID: channelID)
    }

    private static func address(of catalog: ChannelCatalogStore?) -> String? {
        catalog.flatMap { ChannelWaitingRequest.normalizedServer($0.api.baseURL.absoluteString) }
    }

    func composerSession(for store: ChannelStore, draft: ComposerDraft) -> ChannelComposerSession {
        if let session = composerSessions[store.id], session.store === store, session.draft === draft {
            return session
        }
        let session = ChannelComposerSession(store: store, draft: draft)
        composerSessions[store.id] = session
        return session
    }

    /// The key window's channel, or the one the main window last showed.
    var lastUsedChannel: ChannelTarget? {
        activeChannel ?? launchChannel.channelID(serverURL: serverURL).flatMap { target($0) }
    }

    // MARK: Servers

    private func serversDidChange() {
        // A launch address that isn't usable stays in the footer until a server is added.
        let address = catalog?.api.baseURL.absoluteString ?? ""
        if configurationError == nil, address != serverURL { serverURL = address }
        catalogGeneration = UUID()
        observeCatalog(generation: catalogGeneration)
        updateWidget()
    }

    /// Connects a store for a window, sheet or intent that shows it. Pair each with a release.
    func hold(_ store: ChannelStore) { connections.hold(store) }

    /// The last release keeps the store connected for a few seconds, so switching back is live at once.
    func release(_ store: ChannelStore) { connections.release(store) }

    /// Records a window's channel and whether it's key. Every sidebar row reads the open
    /// channels, so a window that reports without a change updates nothing.
    func updateWindow(_ id: UUID, channel: ChannelTarget?, isKey: Bool) {
        let key = isKey ? id : keyWindowID == id ? nil : keyWindowID
        guard windows[id] != channel || key != keyWindowID else { return }
        windows[id] = channel
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
        return ChannelIntents.Screen.onScreen(in: front, screens: screens.values, catalogs: catalogs)
    }

    private func windowsDidChange() {
        let open = Set(windows.values)
        if open != openChannels { openChannels = open }
        let active = keyWindowID.flatMap { windows[$0] }
        if active != activeChannel {
            activeChannel = active
            if let active, !launchOptions.isSnapshot, let catalog = catalogs.first(at: active.serverURL) {
                launchChannel.remember(active.channelID, serverURL: catalog.api.baseURL.absoluteString)
            }
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
        guard !launchOptions.isSnapshot else { return }
        let count = catalogs.reduce(0) {
            $0 + Self.attentionCount(channels: $1.channels, openChannelIDs: openChannelIDs(on: $1))
        }
        let badge = count == 0 ? nil : String(count)
        if badge != dockBadgeLabel {
            dockBadgeLabel = badge
            NSApplication.shared.dockTile.badgeLabel = badge
        }
        for catalog in catalogs where catalog.lastRefreshedAt != nil {
            let server = Self.address(of: catalog)
            notifications.update(channels: catalog.channels,
                                 activeChannelID: activeChannel?.serverURL == server ? activeChannel?.channelID : nil,
                                 serverURL: catalog.api.baseURL.absoluteString)
        }
    }

    /// Brings a channel forward from outside its windows, as notifications and the menu bar do. The
    /// frontmost window selects it, or a new window opens on it when there is none. Without a
    /// channel, or with one on a server that's gone, the frontmost window just comes forward.
    func activate(_ channel: ChannelTarget?, sequence: Int? = nil) {
        let channel = channel.flatMap { catalogs.first(at: $0.serverURL) == nil ? nil : $0 }
        if let channel {
            navigationRequest = .init(channel: channel, sequence: sequence)
        }
        let app = NSApplication.shared
        guard app.isHidden else {
            app.activate()
            return bringForward(channel)
        }
        // Unhiding finishes on a later turn, and until then every window reads as invisible, so
        // looking now would open a second window beside the one coming back.
        if let unhideObserver { NotificationCenter.default.removeObserver(unhideObserver) }
        unhideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUnhideNotification, object: app, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didUnhide(channel) }
        }
        app.activate()
        app.unhide(nil)
    }

    private func didUnhide(_ channel: ChannelTarget?) {
        if let unhideObserver { NotificationCenter.default.removeObserver(unhideObserver) }
        unhideObserver = nil
        bringForward(channel)
    }

    private func bringForward(_ channel: ChannelTarget?) {
        if let window = Self.frontChannelWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let channel {
            openChannelWindow?(channel)
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
        !launchOptions.isSnapshot && performanceBenchmark == nil
    }

    /// What the menu bar extra shows across every server, from the same waiting requests and
    /// working agents as the sidebar.
    var menuBarStatus: MenuBarStatus {
        let failing = catalogs.filter { $0.phase.message != nil }.map(\.name)
        let unreachable = configurationError != nil ? SidebarFooter.server(serverURL)
            : failing.isEmpty ? nil : failing.formatted(.list(type: .and))
        let inputs = catalogs.filter(\.isLoaded).flatMap { catalog in
            let presentation = sidebarPresentation(for: catalog)
            return catalog.channels.compactMap { listed -> MenuBarStatus.Input? in
                guard let target = catalog.target(listed.id) else { return nil }
                return .init(target: target, channel: presentation.channel(listed),
                             working: presentation.working(listed, agents: presentation.agents(listed)))
            }
        }
        return MenuBarStatus(requests: catalogs.waitingRequests(open: openChannels), inputs,
                             unreachableHost: unreachable)
    }

    /// Keeps the status item, the widget and the Dock in step with activity, including who's working.
    private func observeMenuBarActivity() {
        let status = withObservationTracking {
            for catalog in catalogs { _ = catalog.lastRefreshedAt }
            return menuBarStatus
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMenuBarActivity() }
        }
        menuBar.update(isActive: status.isActive)
        updateWidget()
        dockAttention.update(status: status, usable: Set(catalogs.compactMap {
            $0.isLoaded && $0.phase.message == nil ? Self.address(of: $0) : nil
        }))
    }

    private func updateWidget() {
        widgetSnapshots.update(catalogs.map { catalog in
            .init(serverURL: catalog.api.baseURL.absoluteString, isOffline: catalog.phase.message != nil,
                  waiting: catalog.isLoaded ? catalog.waitingRequests(openChannelIDs: openChannelIDs(on: catalog)) : nil)
        })
    }

    /// How the sidebar shows a server's channels, given which of them windows have open.
    func sidebarPresentation(for catalog: ChannelCatalogStore?) -> ChannelSidebarPresentation {
        .init(catalog: catalog, openChannelIDs: openChannelIDs(on: catalog))
    }

    /// The channels on one server that the Dock's badge counts.
    static func attentionCount(channels: [Channel], openChannelIDs: Set<String>) -> Int {
        channels.filter { $0.sidebarAttention(isOpen: openChannelIDs.contains($0.id)) != nil }.count
    }

    private func observeCatalog(generation: UUID) {
        guard generation == catalogGeneration else { return }
        withObservationTracking {
            for catalog in catalogs {
                _ = catalog.channels
                _ = catalog.lastRefreshedAt
            }
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
        for catalog in catalogs {
            folders.refresh(paths: catalog.channels.compactMap(\.directory), server: catalog.api.baseURL)
        }
    }

    /// Retry and View > Refresh, the catalog refreshes someone asks for, on every server.
    func refreshCatalog() {
        for catalog in catalogs where refreshing.insert(ObjectIdentifier(catalog)).inserted {
            Task {
                await catalog.refresh()
                refreshing.remove(ObjectIdentifier(catalog))
            }
        }
    }

    func isRefreshing(_ catalog: ChannelCatalogStore) -> Bool {
        refreshing.contains(ObjectIdentifier(catalog))
    }

    func openInToyBox(_ channel: ChannelTarget) {
        guard let url = catalogs.first(at: channel.serverURL)?.api.channelURL(channelID: channel.channelID) else { return }
        NSWorkspace.shared.open(url)
    }

    func channelURL(channelID: String, files: [WorkspaceFile] = []) -> URL? {
        api?.channelURL(channelID: channelID, files: files)
    }
}

struct ChannelNavigationRequest: Identifiable {
    let id = UUID()
    let channel: ChannelTarget
    let sequence: Int?
}
