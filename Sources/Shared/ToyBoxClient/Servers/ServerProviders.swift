import ToyBoxKit
import Foundation
import Observation

/// A server's model providers and their usage, which Settings shows.
/// Reads start when Settings shows the server. Each enabled, ready provider's subscription is read
/// on its own, at most once a minute, so a slow CLI never holds up the others. Retry skips the wait.
@MainActor @Observable
public final class ServerProviders {
    public enum Usage: Equatable, Sendable {
        case loading
        case loaded(ModelProviderSubscription)
        /// An account on an API key, which the server answers as `null`.
        case none
        case failed(String)
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public var provider: ModelProvider
        /// Nil unless the provider is enabled and ready, so Settings can read usage.
        public var usage: Usage?
        public var id: String { provider.id }
    }

    public static let refreshInterval: TimeInterval = 60

    /// The server's list, in its Settings order. Empty until the first successful read.
    public private(set) var list: [ModelProvider] = []

    public var entries: [Entry] {
        list.map { Entry(provider: $0, usage: $0.readsUsage ? usage[$0.id] : nil) }
    }

    private var usage: [String: Usage] = [:]
    @ObservationIgnored private var fetchedAt: [String: Date] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let api: ChannelAPI
    @ObservationIgnored private let now: () -> Date

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
                usage[id] = .none
            }
        } catch {
            usage[id] = .failed(error.localizedDescription)
        }
        fetchedAt[id] = now()
    }
}
