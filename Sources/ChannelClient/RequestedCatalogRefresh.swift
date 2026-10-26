import Observation

/// Tracks user-requested refreshes separately from background polling.
@MainActor @Observable
public final class RequestedCatalogRefresh {
    private var catalog: ObjectIdentifier?

    public init() {}

    public func isRunning(for catalog: ChannelCatalogStore) -> Bool {
        self.catalog == ObjectIdentifier(catalog) && catalog.isLoading
    }

    /// Joins an in-flight refresh and stays active until that attempt resolves.
    public func run(_ catalog: ChannelCatalogStore) async {
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
