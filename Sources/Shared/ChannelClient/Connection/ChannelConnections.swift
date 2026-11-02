/// Counts who holds each channel store, and keeps a store its last holder released connected for a
/// short linger. Switching back to a channel you just left then lands on a connected store, without a
/// first frame that shows the composer connecting and holds off the transcript's landing and the
/// working row.
///
/// A lingering store has no view, so it never marks read, and notifications come from the catalog,
/// which a connection doesn't change. Only the newest `capacity` stores linger, so leaving a third
/// channel disconnects the oldest at once.
@MainActor public final class ChannelConnections {
    public let linger: Duration
    public let capacity: Int
    private var held: [ObjectIdentifier: (store: ChannelStore, count: Int)] = [:]
    /// Oldest first.
    private var lingering: [(store: ChannelStore, expiry: Task<Void, Never>)] = []

    public init(linger: Duration = .seconds(5), capacity: Int = 2) {
        self.linger = linger
        self.capacity = capacity
    }

    /// Held and lingering stores, each with its own connection.
    public var stores: [ChannelStore] { held.values.map(\.store) + lingering.map(\.store) }

    public func hold(_ store: ChannelStore) {
        let key = ObjectIdentifier(store)
        if let entry = held[key] {
            held[key] = (store, entry.count + 1)
            return
        }
        if let index = lingering.firstIndex(where: { $0.store === store }) {
            lingering.remove(at: index).expiry.cancel()
        }
        held[key] = (store, 1)
        // Opening a channel places its New divider, at once when the store stayed connected and
        // otherwise once its reconnect catches up.
        store.captureUnreadBoundary()
        // Does nothing while the store is still connected or retrying.
        store.connect()
    }

    public func release(_ store: ChannelStore) {
        let key = ObjectIdentifier(store)
        guard let entry = held[key] else { return }
        guard entry.count == 1 else {
            held[key] = (store, entry.count - 1)
            return
        }
        held.removeValue(forKey: key)
        guard capacity > 0, linger > .zero else {
            store.disconnect()
            return
        }
        let linger = linger
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled else { return }
            self?.expire(key)
        }
        lingering.append((store, expiry))
        while lingering.count > capacity {
            let oldest = lingering.removeFirst()
            oldest.expiry.cancel()
            oldest.store.disconnect()
        }
    }

    /// Disconnects every store at once, as a server change does.
    public func disconnectAll() {
        for entry in held.values { entry.store.disconnect() }
        for entry in lingering {
            entry.expiry.cancel()
            entry.store.disconnect()
        }
        held.removeAll()
        lingering.removeAll()
    }

    private func expire(_ key: ObjectIdentifier) {
        guard let index = lingering.firstIndex(where: { ObjectIdentifier($0.store) == key }) else { return }
        lingering.remove(at: index).store.disconnect()
    }
}
