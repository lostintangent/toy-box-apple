import ChannelClient
import ChannelKit
import Foundation
import OSLog
import WidgetKit

@MainActor
public final class MobileWidgetSnapshotPublisher {
    private let file: URL
    private let reload: @MainActor () -> Void
    private var previous: NeedsYouSnapshot?
    /// One per catalog, so a server change forgets the last one's requests.
    private var requests: ChannelWaitingRequests?
    private var generation = UUID()
    private let logger = Logger(subsystem: "dev.toybox.mobile", category: "Widget")

    private enum Failure: LocalizedError {
        case unsupportedSnapshot
        var errorDescription: String? { "Toy Box cannot read this version of its saved widget snapshot." }
    }

    public init(directory: URL? = nil,
                reload: @escaping @MainActor () -> Void = {
                    WidgetCenter.shared.reloadTimelines(ofKind: NeedsYouSnapshot.kind)
                }) throws {
        let directory = try directory ?? MobileSharedContainer.url()
        file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        self.reload = reload
        do {
            previous = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
            guard previous?.version == 1 else { throw Failure.unsupportedSnapshot }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            previous = nil
        }
    }

    public func update(catalog: ChannelCatalogStore?, serverURL: String) async throws {
        let token = UUID()
        generation = token
        guard let catalog, catalog.api.baseURL.absoluteString == serverURL,
              catalog.isLoaded, catalog.phase.message == nil else {
            var snapshot = previous?.serverURL == serverURL ? previous : nil
            if snapshot != nil { snapshot?.isOffline = true }
            try publish(snapshot ?? NeedsYouSnapshot(
                serverURL: serverURL, updatedAt: .now, isOffline: true, isAvailable: false,
                waitingCount: 0, requests: []
            ))
            return
        }
        let snapshot = try await resolvedSnapshot(catalog: catalog, serverURL: serverURL, token: token,
                                                  allowsPartialHistory: true)
        try publish(snapshot)
    }

    public func refresh(session: URLSession = .shared, now: Date = .now) async throws -> NeedsYouSnapshot? {
        let directory = file.deletingLastPathComponent()
        let selected = try MobilePushRegistrationStore(directory: directory).current
        guard let serverURL = selected?.serverURL ?? previous?.serverURL else { return nil }
        let token = UUID()
        generation = token
        let snapshot: NeedsYouSnapshot
        do {
            snapshot = try await withThrowingTaskGroup(of: NeedsYouSnapshot.self) { group in
                group.addTask {
                    try await self.fetchedSnapshot(serverURL: serverURL, session: session, token: token)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        } catch {
            if Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled { throw error }
            logger.error("Could not refresh the widget: \(error.localizedDescription)")
            var cached = previous?.serverURL == serverURL ? previous : nil
            if cached != nil { cached?.isOffline = true }
            snapshot = cached ?? NeedsYouSnapshot(
                serverURL: serverURL, updatedAt: now, isOffline: true, isAvailable: false,
                waitingCount: 0, requests: [])
        }
        try Task.checkCancellation()
        guard generation == token,
              try MobilePushRegistrationStore(directory: directory).current == selected else {
            throw CancellationError()
        }
        try publish(snapshot, now: now)
        return previous
    }

    private func fetchedSnapshot(serverURL: String, session: URLSession, token: UUID) async throws -> NeedsYouSnapshot {
        let catalog = ChannelCatalogStore(api: try ChannelAPI(serverURL: serverURL, session: session))
        await catalog.refresh()
        try Task.checkCancellation()
        if let failure = catalog.phase.failure { throw failure }
        return try await resolvedSnapshot(
            catalog: catalog, serverURL: serverURL, token: token, allowsPartialHistory: false)
    }

    private func resolvedSnapshot(catalog: ChannelCatalogStore, serverURL: String, token: UUID,
                                  allowsPartialHistory: Bool) async throws -> NeedsYouSnapshot {
        guard catalog.state != nil else { throw ChannelAPIError.invalidResponse }
        let requests = self.requests.flatMap { $0.catalog === catalog ? $0 : nil } ?? ChannelWaitingRequests(catalog: catalog)
        self.requests = requests
        var offline = false
        for entry in requests.entries() {
            guard entry.sequence < Int.max, ChannelWaitingRequest.Identity(
                serverURL: serverURL, channelID: entry.channel.id, sequence: entry.sequence
            ) != nil else { throw ChannelAPIError.invalidMessage("A waiting request has an invalid sequence.") }
            do {
                _ = try await requests.message(channelID: entry.channel.id, sequence: entry.sequence)
            } catch {
                if Task.isCancelled || error is CancellationError
                    || (error as? URLError)?.code == .cancelled { throw error }
                if !allowsPartialHistory { throw error }
                offline = true
                logger.error("Could not load a widget request: \(error.localizedDescription)")
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
        }
        return NeedsYouSnapshot(serverURL: serverURL, updatedAt: .now, isOffline: offline, isAvailable: true,
                                waiting: requests.entries())
    }

    func publish(_ proposed: NeedsYouSnapshot, now: Date = .now) throws {
        guard let snapshot = proposed.replacing(previous, at: now) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        previous = snapshot
        reload()
    }
}
