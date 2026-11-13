import Foundation
import Observation

/// What a server answers about its release.
public struct ServerVersion: Codable, Equatable, Sendable {
    /// The release the server runs.
    public var version: String
    /// The installed release, which a restart starts. Nil when the server runs from source, so it
    /// has nothing to update or restart into.
    public var installedVersion: String?

    public init(version: String, installedVersion: String?) {
        self.version = version
        self.installedVersion = installedVersion
    }

    /// A restart would start a different release. It reads the installed release, so it holds on
    /// every device, whichever one ran the update.
    public var isRestartPending: Bool {
        guard let installedVersion else { return false }
        return installedVersion != version
    }
}

/// What `GET /api/v1/server` answers: the server's identity, name, accent, releases and links.
public struct ServerInfo: Codable, Equatable, Sendable {
    /// An identity the server makes once and keeps, whatever address reaches it.
    public var id: String
    /// The name every device and lead sees.
    public var name: String
    /// The server's accent, `#` and six hex digits.
    public var accentColor: String
    public var release: ServerVersion
    /// The origins of the servers this one links, in link order.
    public var links: [String]

    public init(id: String, name: String, accentColor: String, release: ServerVersion, links: [String]) {
        self.id = id
        self.name = name
        self.accentColor = accentColor
        self.release = release
        self.links = links
    }

    private enum CodingKeys: String, CodingKey { case id, name, accentColor, links }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        accentColor = try container.decode(String.self, forKey: .accentColor)
        release = try ServerVersion(from: decoder)
        links = try container.decode([String].self, forKey: .links)
    }

    public func encode(to encoder: any Encoder) throws {
        try release.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(accentColor, forKey: .accentColor)
        try container.encode(links, forKey: .links)
    }
}

/// A server's release in Settings' server list: checking for a newer one and restarting onto it.
/// Each catalog has one, so every window agrees, and the catalog's `refreshServer()` reads it with
/// the server's name and links, as each catalog stream that connects does too. The list's
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

    /// The server's last answer. Nil until it answers.
    public private(set) var version: ServerVersion?
    public private(set) var outcome: Outcome?
    private var isChecking = false
    /// The catalog's stream isn't live and hasn't failed for the grace, or it has just reconnected
    /// and the read that follows hasn't answered. Its catalog keeps it current.
    private(set) var isReconnecting = false
    /// Each change in the catalog's connection, so a read after a reconnect that the stream has since
    /// dropped again doesn't end the reconnect.
    @ObservationIgnored private var connection = UUID()
    @ObservationIgnored private let api: ChannelAPI
    /// The catalog that reads the server, with its name and links.
    @ObservationIgnored weak var catalog: ChannelCatalogStore?

    public init(api: ChannelAPI) {
        self.api = api
    }

    /// Nil when the row offers neither action and isn't reconnecting, because the server hasn't
    /// answered or has no installed release.
    public var phase: Phase? {
        if isChecking { return .checking }
        if isReconnecting { return .reconnecting }
        guard let version, version.installedVersion != nil else { return nil }
        return version.isRestartPending ? .restartPending : .idle
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
            if ChannelManagementWriteRecovery.Phase.isRequired(after: error) { await catalog?.refreshServer() }
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

    /// The catalog's stream delivered its first catalog, so the server may have restarted or been
    /// renamed. The row stays reconnecting until the catalog reads the server again.
    func catalogConnected() {
        let read = UUID()
        connection = read
        isReconnecting = true
        Task {
            await catalog?.refreshServer()
            if connection == read { isReconnecting = false }
        }
    }

    /// The server's releases, as it answered them.
    func apply(_ current: ServerVersion) {
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
