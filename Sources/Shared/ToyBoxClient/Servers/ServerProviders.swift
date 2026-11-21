import ToyBoxKit
import Foundation
import Observation

/// A server's model providers, their usage and their updates, which Settings shows.
/// Reads start when Settings shows the server. Each enabled, ready provider's subscription is read
/// on its own, at most once a minute, so a slow CLI never holds up the others. Usage belongs to the
/// list and has no failure of its own, so a failed read shows none and the next `appear()` reads it
/// again. Check for Updates updates every provider that's on and installed at once, and what each
/// installed stays until the next check, until Settings closes and calls `clearUpdates()`, or until
/// the server reconnects, when the list is read again for the versions it runs.
@MainActor @Observable
public final class ServerProviders {
    public enum Usage: Equatable, Sendable {
        case loading
        case loaded(ModelProviderSubscription)
        /// An account on an API key, which the server answers as `null`.
        case none
    }

    /// A provider's update, while it runs and once it installs something new. One that finds nothing
    /// newer, or fails, leaves no update, so the row shows its version again.
    public enum Update: Equatable, Sendable {
        /// A spinner in the version's place while the server installs whatever is newer, or while
        /// it reconnects after an update and the list is read again.
        case updating
        /// The update installed `to`, which runs once the server restarts. `from` is the version the
        /// list showed, nil when it showed none.
        case updated(from: String?, to: String)
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public var provider: ModelProvider
        /// Nil while there's none to show: the provider isn't enabled and ready, or its read failed.
        public var usage: Usage?
        /// Nil unless this provider is updating, or the last Check for Updates installed something new.
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
    /// What each finished update installed, by provider, only for those that installed something new.
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
                group.addTask { await self.refresh(id) }
            }
        }
    }

    private func refresh(_ id: String) async {
        if inFlight.contains(id) { return }
        if let fetchedAt = fetchedAt[id], now().timeIntervalSince(fetchedAt) < Self.refreshInterval { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        if usage[id] == nil { usage[id] = .loading }
        do {
            let subscription = try await api.providerSubscription(id: id)
            usage[id] = subscription.map(Usage.loaded) ?? Usage.none
            fetchedAt[id] = now()
        } catch {
            usage[id] = nil
        }
    }

    /// Check for Updates shows on a connected server that updates its providers while any provider
    /// is on and installed.
    public var offersUpdateCheck: Bool {
        guard let catalog, catalog.phase == .connected, catalog.update.release?.updatesProviders == true
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

    /// How many new versions the last check installed, which a provider runs only once the server
    /// restarts. Zero while rows spin.
    public var newVersions: Int {
        entries.count { if case .updated = $0.update { true } else { false } }
    }

    /// While results show, a server that's reconnecting or restarting may come back running new
    /// versions, so their rows spin until it's back and the list is read again.
    private var isAwaitingServer: Bool {
        !results.isEmpty && (isRereading || catalog?.update.isAwaitingServer == true)
    }

    private func update(_ provider: ModelProvider) async {
        defer { updating.remove(provider.id) }
        guard let answer = try? await api.updateProvider(id: provider.id), answer.updated else { return }
        results[provider.id] = .updated(from: provider.version, to: answer.version)
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
