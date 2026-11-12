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
/// one Check for Updates checks every server together with `checkForUpdates()`.
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
        /// A spinner until the server reconnects running the installed release.
        case restarting
    }

    /// How the last check or restart ended. It stays until the next check, until Settings closes and
    /// calls `clearOutcome()`, or until a read finds the server's releases changed.
    public enum Outcome: Equatable, Sendable {
        /// The check found nothing newer.
        case upToDate
        /// The check or restart failed, with the words to show.
        case failed(String)
    }

    private enum Activity { case checking, restarting }

    /// The server's last answer. Nil until it answers, and for a server that predates the route.
    public private(set) var version: ServerVersion?
    public private(set) var outcome: Outcome?
    private var activity: Activity?
    /// Something has read the server, so each connection reads it again.
    @ObservationIgnored private var isRead = false
    @ObservationIgnored private let api: ChannelAPI
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var restartDeadline: Task<Void, Never>?

    /// How long a restarted server has to come back before its row says it didn't.
    static let restartWait: TimeInterval = 60
    /// The failure a row shows when its server hasn't come back within `restartWait`.
    public static let unreturnedRestart = "Didn't come back after restarting"

    /// `sleep` times the restart's deadline. Tests pass one they end instead of waiting.
    public init(api: ChannelAPI,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.api = api
        self.sleep = sleep
    }

    /// Nil when the row offers neither action, because the server hasn't answered, predates the
    /// route or has no installed release.
    public var phase: Phase? {
        switch activity {
        case .checking: return .checking
        case .restarting: return .restarting
        case nil:
            guard let version, version.installedVersion != nil else { return nil }
            return version.isRestartPending ? .restartPending : .idle
        }
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
        guard activity == nil, let installed = version?.installedVersion else { return }
        activity = .checking
        outcome = nil
        defer { activity = nil }
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

    /// Asks the server to restart onto its installed release. It answers before it shuts down, so
    /// the row stays `.restarting` until the catalog's stream reconnects and a read finds the
    /// installed release running. A rejection, or a server it can't reach, offers Restart again.
    /// Any other failure may still have restarted, so the row reads the server. One that answers
    /// decides, and one that doesn't is likely restarting, so the row waits for it. A server that
    /// hasn't come back within `restartWait` fails with `unreturnedRestart`, and the row still
    /// returns to its version once a read reaches it.
    public func restart() async {
        guard phase == .restartPending else { return }
        activity = .restarting
        outcome = nil
        do {
            try await api.restartServer()
        } catch {
            if ChannelManagementWriteRecovery.Phase.isRequired(after: error) {
                do { try await read() } catch {
                    awaitReturn()
                    return
                }
            }
            guard activity == .restarting else { return }
            activity = nil
            outcome = .failed(error.localizedDescription)
            return
        }
        awaitReturn()
    }

    /// The catalog's stream delivered its first catalog, so the server may have restarted.
    func catalogConnected() {
        guard isRead else { return }
        Task { await refresh() }
    }

    private func read() async throws {
        isRead = true
        do { apply(try await api.server()) }
        catch ChannelAPIError.http(status: 404, message: _) { apply(nil) }
    }

    private func apply(_ current: ServerVersion?) {
        if current != version || outcome == .failed(Self.unreturnedRestart) { outcome = nil }
        version = current
        if activity == .restarting, current?.isRestartPending != true {
            activity = nil
            restartDeadline?.cancel()
        }
    }

    private func awaitReturn() {
        guard activity == .restarting else { return }
        restartDeadline?.cancel()
        restartDeadline = Task { [weak self, sleep] in
            try? await sleep(Self.restartWait)
            guard !Task.isCancelled, let self, activity == .restarting else { return }
            activity = nil
            outcome = .failed(Self.unreturnedRestart)
        }
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
    /// once, and returns when every check ends. Servers that are offline or have no installed release
    /// are skipped, and every row's last outcome clears.
    @MainActor public func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        for catalog in self { catalog.update.clearOutcome() }
        let checking = filter { $0.phase == .connected && $0.update.version?.installedVersion != nil }
        await withTaskGroup(of: Void.self) { group in
            for catalog in checking { group.addTask { await catalog.update.check() } }
        }
    }
}
