import Foundation
import Observation

/// What a server answers about its release.
public struct ServerVersion: Codable, Equatable, Sendable {
    /// The release the server runs.
    public var version: String
    /// The release on disk, which a restart starts. Nil when no package manager owns the install,
    /// so the server can't update or restart itself.
    public var installedVersion: String?

    public init(version: String, installedVersion: String?) {
        self.version = version
        self.installedVersion = installedVersion
    }

    /// A restart would start a different release. It reads the release on disk, so it holds on every
    /// device, whichever one ran the update.
    public var isRestartPending: Bool {
        guard let installedVersion else { return false }
        return installedVersion != version
    }
}

/// A server's release in Settings' server list: checking for a newer one and restarting onto it.
/// Each catalog has one, so every window agrees. Settings reads it with `refresh()` while it shows
/// the list, and once something has, each catalog stream that connects reads it again. The list's
/// one Check for Updates checks every server together with `checkForUpdates()`. A restart is an
/// ordinary disconnect, so the row shows `.reconnecting` for it as it would for any other.
@MainActor @Observable
public final class ServerUpdate {
    /// What the server's row offers.
    public enum Phase: Equatable, Sendable {
        /// Check for Updates.
        case idle
        /// A spinner while the server installs whatever is newer.
        case checking
        /// Restart, because the installed release isn't the one running.
        case restartPending
        /// A spinner in the version's place while the app reconnects to the server, for any reason,
        /// until it connects and reads the server again, so a stale release can't offer Restart. A
        /// server that fails for the catalog's grace shows that failure instead.
        case reconnecting
    }

    /// How the last check or restart ended. It stays until the next check, until Settings closes and
    /// calls `clearOutcome()`, or until a read finds the server's releases changed.
    public enum Outcome: Equatable, Sendable {
        /// The check found nothing newer.
        case upToDate
        /// The check or restart failed, with the words to show.
        case failed(String)
    }

    /// The server's last answer. Nil until it answers, and for a server that predates the route.
    public private(set) var version: ServerVersion?
    public private(set) var outcome: Outcome?
    private var isChecking = false
    /// The catalog's stream isn't live and hasn't failed for the grace, or it has just reconnected
    /// and the read that follows hasn't answered. Its catalog keeps it current.
    private(set) var isReconnecting = false
    /// Each change in the catalog's connection, so a read after a reconnect that the stream has since
    /// dropped again doesn't end the reconnect.
    @ObservationIgnored private var connection = UUID()
    /// Something has read the server, so each connection reads it again.
    @ObservationIgnored private var isRead = false
    @ObservationIgnored private let api: ChannelAPI

    public init(api: ChannelAPI) {
        self.api = api
    }

    /// Nil when the row offers neither action and isn't reconnecting, because the server hasn't
    /// answered, predates the route or has no installed release.
    public var phase: Phase? {
        if isChecking { return .checking }
        if isReconnecting { return .reconnecting }
        guard let version, version.installedVersion != nil else { return nil }
        return version.isRestartPending ? .restartPending : .idle
    }

    /// Reads the server. A failure keeps the last answer, since the server's connection status
    /// already says it's unreachable.
    public func refresh() async {
        try? await read()
    }

    /// Asks the server to install whatever is newer, which can take minutes, and offers Restart if
    /// it did. A server already waiting to restart checks too, since something newer than its
    /// installed release may have shipped. A rejection keeps the row as it was, with the server's
    /// words. Any other failure may still have installed, so the row reads the server, and shows the
    /// failure only if nothing new was installed.
    public func check() async {
        guard !isChecking, let installed = version?.installedVersion else { return }
        isChecking = true
        outcome = nil
        defer { isChecking = false }
        do {
            let current = try await api.updateServer()
            apply(current)
            if !current.isRestartPending { outcome = .upToDate }
        } catch {
            if ChannelManagementWriteRecovery.Phase.isRequired(after: error) { await refresh() }
            if version?.installedVersion == installed { outcome = .failed(error.localizedDescription) }
        }
    }

    /// Settings closed, so the row forgets how its last check or restart ended.
    public func clearOutcome() {
        if outcome != nil { outcome = nil }
    }

    /// Asks the server to restart onto its installed release. One that accepts answers, then drops
    /// every connection at once, so the row reconnects as it would for any disconnect and then shows
    /// the release the server came back running. A rejection keeps Restart, with the server's words.
    /// A restart whose answer never arrives needs nothing, since the catalog's connection reports a
    /// server that doesn't come back.
    public func restart() async {
        guard phase == .restartPending else { return }
        outcome = nil
        do {
            try await api.restartServer()
        } catch {
            guard case .http? = error as? ChannelAPIError else { return }
            outcome = .failed(error.localizedDescription)
        }
    }

    /// The catalog's stream is open but not live, and hasn't failed for the grace.
    func catalogReconnecting() {
        connection = UUID()
        isReconnecting = true
    }

    /// The catalog's stream failed for the grace or stopped, so the row shows that instead.
    func catalogDisconnected() {
        connection = UUID()
        isReconnecting = false
    }

    /// The catalog's stream delivered its first catalog, so the server may have restarted. Once
    /// something has read the server, the row stays reconnecting until it reads the server again.
    func catalogConnected() {
        let read = UUID()
        connection = read
        isReconnecting = isRead
        guard isRead else { return }
        Task {
            await refresh()
            if connection == read { isReconnecting = false }
        }
    }

    private func read() async throws {
        isRead = true
        do { apply(try await api.server()) }
        catch ChannelAPIError.http(status: 404, message: _) { apply(nil) }
    }

    private func apply(_ current: ServerVersion?) {
        if current != version { outcome = nil }
        version = current
    }
}

extension [ChannelCatalogStore] {
    /// Settings' server list offers Check for Updates while some server has an installed release.
    @MainActor public var offersUpdateCheck: Bool {
        contains { $0.update.version?.installedVersion != nil }
    }

    /// Some server is checking, so Check for Updates dims until every check ends.
    @MainActor public var isCheckingForUpdates: Bool {
        contains { $0.update.phase == .checking }
    }

    /// Asks every connected server with an installed release to install whatever is newer, all at
    /// once, and returns when every check ends. Servers that are offline or reconnecting, or have no
    /// installed release, are skipped, and every row's last outcome clears.
    @MainActor public func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        for catalog in self { catalog.update.clearOutcome() }
        let checking = filter {
            $0.phase == .connected && !$0.update.isReconnecting && $0.update.version?.installedVersion != nil
        }
        await withTaskGroup(of: Void.self) { group in
            for catalog in checking { group.addTask { await catalog.update.check() } }
        }
    }
}
