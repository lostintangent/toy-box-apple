import ToyBoxKit
import Foundation
import Observation

/// A server's model providers, their usage and their updates, which Settings shows.
/// Reads start when Settings shows the server. Each enabled, ready provider's subscription is read
/// on its own, at most once a minute, so a slow CLI never holds up the others. Retry skips the wait.
/// Check for Updates updates every provider that's on and installed at once, and each result stays
/// until the next check, until Settings closes and calls `clearUpdates()`, or until the server
/// reconnects, when the list is read again for the versions it runs.
@MainActor @Observable
public final class ServerProviders {
    public enum Usage: Equatable, Sendable {
        case loading
        case loaded(ModelProviderSubscription)
        /// An account on an API key, which the server answers as `null`.
        case none
        case failed(String)
    }

    /// How a provider's last update went.
    public enum Update: Equatable, Sendable {
        /// A spinner in the version's place while the server installs whatever is newer, or while
        /// it reconnects after an update and the list is read again.
        case updating
        case upToDate
        /// The update installed `to`, which runs once the server restarts. `from` is the version the
        /// list showed, nil when it showed none.
        case updated(from: String?, to: String)
        /// The update failed, with the words to show, in the server's words for a refusal or failure.
        case failed(String)
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public var provider: ModelProvider
        /// Nil unless the provider is enabled and ready, so Settings can read usage.
        public var usage: Usage?
        /// Nil unless the last Check for Updates updated this provider.
        public var update: Update?
        public var id: String { provider.id }
    }

    public static let refreshInterval: TimeInterval = 60

    /// The server's list, in its Settings order. Empty until the first successful read.
    public private(set) var list: [ModelProvider] = []

    public var entries: [Entry] {
        let awaitingServer = isAwaitingServer
        return list.map { provider in
            let result = results[provider.id]
            let update: Update? = updating.contains(provider.id) || (awaitingServer && result != nil)
                ? .updating : result
            return Entry(provider: provider, usage: provider.readsUsage ? usage[provider.id] : nil, update: update)
        }
    }

    private var usage: [String: Usage] = [:]
    @ObservationIgnored private var fetchedAt: [String: Date] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// The providers whose update the server hasn't answered.
    private var updating: Set<String> = []
    /// How each finished update went, by provider.
    private var results: [String: Update] = [:]
    /// The server reconnected while results showed, and the list it runs now hasn't been read.
    private var isRereading = false
    /// Each new read after a reconnect, check, or close, so a read that one has replaced changes
    /// nothing when it answers.
    @ObservationIgnored private var reread = UUID()
    @ObservationIgnored private let api: ChannelAPI
    @ObservationIgnored private let now: () -> Date
    /// The catalog that reads this server, with its name, connection and release.
    @ObservationIgnored weak var catalog: ChannelCatalogStore?

    /// `now` measures the one-minute wait. Tests pass a clock they move instead of waiting.
    public init(api: ChannelAPI, now: @escaping () -> Date = { .now }) {
        self.api = api
        self.now = now
    }

    /// Settings is showing this server, so read the provider list and any usage that's due.
    public func appear() async {
        do {
            list = try await api.providers()
        } catch {
            return
        }
        let live = Set(list.filter(\.readsUsage).map(\.id))
        usage = usage.filter { live.contains($0.key) }
        fetchedAt = fetchedAt.filter { live.contains($0.key) }
        await withTaskGroup(of: Void.self) { group in
            for id in list.filter(\.readsUsage).map(\.id) {
                group.addTask { await self.refresh(id, force: false) }
            }
        }
    }

    /// Reads this provider's subscription now, even if it was read within the minute.
    public func retry(_ id: String) async {
        guard list.contains(where: { $0.id == id && $0.readsUsage }) else { return }
        await refresh(id, force: true)
    }

    private func refresh(_ id: String, force: Bool) async {
        if inFlight.contains(id) { return }
        if !force, let fetchedAt = fetchedAt[id], now().timeIntervalSince(fetchedAt) < Self.refreshInterval {
            return
        }
        inFlight.insert(id)
        if force || usage[id] == nil { usage[id] = .loading }
        defer { inFlight.remove(id) }
        do {
            if let subscription = try await api.providerSubscription(id: id) {
                usage[id] = .loaded(subscription)
            } else {
                usage[id] = Usage.none
            }
        } catch {
            usage[id] = .failed(error.localizedDescription)
        }
        fetchedAt[id] = now()
    }

    /// Check for Updates shows on a connected server that updates its providers while any provider
    /// is on and installed.
    public var offersUpdateCheck: Bool {
        guard let catalog, catalog.phase == .connected, catalog.update.version?.updatesProviders == true
        else { return false }
        return list.contains(where: \.isUpdatable)
    }

    /// Some update is under way, or rows are spinning while the server comes back from one, so
    /// Check for Updates dims until they end.
    public var isCheckingForUpdates: Bool { !updating.isEmpty || isAwaitingServer }

    /// Updates every provider that's on and installed, all at once with one request each, sent once
    /// and never retried, and returns when every update ends. Off and Not Installed are skipped, and
    /// the last check's results clear.
    public func checkForUpdates() async {
        guard offersUpdateCheck, !isCheckingForUpdates else { return }
        clearUpdates()
        let providers = list.filter(\.isUpdatable)
        updating = Set(providers.map(\.id))
        await withTaskGroup(of: Void.self) { group in
            for provider in providers { group.addTask { await self.update(provider) } }
        }
    }

    /// Settings closed, so the rows forget their results. An update still under way keeps going,
    /// and its result shows when Settings next does.
    public func clearUpdates() {
        reread = UUID()
        if !results.isEmpty { results = [:] }
        if isRereading { isRereading = false }
    }

    /// Once an update installs a new version, the section asks for a restart, since a provider
    /// keeps running its old version until then. Nil while nothing changed or rows are spinning.
    public var restartMessage: String? {
        let changed = entries.filter { if case .updated = $0.update { true } else { false } }.count
        guard changed > 0, let catalog else { return nil }
        return "Restart \(catalog.name) to use the new \(changed == 1 ? "version" : "versions")."
    }

    /// While results show, a server that's reconnecting or restarting may come back running new
    /// versions, so their rows spin until it's back and the list is read again.
    private var isAwaitingServer: Bool {
        !results.isEmpty && (isRereading || catalog?.update.isAwaitingServer == true)
    }

    private func update(_ provider: ModelProvider) async {
        defer { updating.remove(provider.id) }
        do {
            let answer = try await api.updateProvider(id: provider.id)
            results[provider.id] = answer.updated ? .updated(from: provider.version, to: answer.version) : .upToDate
        } catch {
            results[provider.id] = .failed(error.localizedDescription)
        }
    }

    /// The catalog's stream delivered its first catalog, so the server may have restarted onto new
    /// versions. Any results spin until the list is read again, then clear, whether or not it
    /// answers, since nothing says whether the server restarted.
    func catalogConnected() {
        guard !results.isEmpty else { return }
        let read = UUID()
        reread = read
        isRereading = true
        Task {
            let current = try? await api.providers()
            guard reread == read else { return }
            if let current { list = current }
            clearUpdates()
        }
    }
}
