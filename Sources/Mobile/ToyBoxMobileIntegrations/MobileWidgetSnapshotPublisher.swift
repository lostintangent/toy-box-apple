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
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            previous = nil
            return
        }
        let version = try NeedsYouSnapshot.version(of: data)
        guard version <= NeedsYouSnapshot.currentVersion else { throw Failure.unsupportedSnapshot }
        // An older version's snapshot is written over, as if there were none.
        previous = version == NeedsYouSnapshot.currentVersion
            ? try JSONDecoder().decode(NeedsYouSnapshot.self, from: data) : nil
    }

    /// Publishes the waiting requests the app's channel list shows, so both agree. A server whose
    /// catalog isn't current keeps its last requests, out of date.
    public func update(catalogs: [ChannelCatalogStore]) throws {
        generation = UUID()
        let now = Date.now
        try publish(NeedsYouSnapshot(servers: catalogs.map { catalog in
            let serverURL = catalog.api.baseURL.absoluteString
            guard catalog.isLoaded, catalog.phase.message == nil else {
                return .offline(serverURL, in: previous, at: now)
            }
            return try part(of: catalog, serverURL: serverURL)
        }))
    }

    /// Fetches every registered server's waiting requests without the app, as the widget's timeline
    /// and a push do.
    public func refresh(session: URLSession = .shared, now: Date = .now) async throws -> NeedsYouSnapshot? {
        let directory = file.deletingLastPathComponent()
        let registrations = try MobilePushRegistrationStore(directory: directory).registrations
        let servers = registrations.isEmpty ? previous?.servers.map(\.serverURL) ?? [] : registrations.map(\.serverURL)
        guard !servers.isEmpty else { return nil }
        let token = UUID()
        generation = token
        let parts = try await withThrowingTaskGroup(of: (Int, NeedsYouSnapshot.Server).self) { group in
            for (index, serverURL) in servers.enumerated() {
                group.addTask { (index, try await self.part(serverURL: serverURL, session: session, now: now)) }
            }
            var parts: [NeedsYouSnapshot.Server?] = Array(repeating: nil, count: servers.count)
            for try await (index, part) in group { parts[index] = part }
            return parts.compactMap(\.self)
        }
        try Task.checkCancellation()
        guard generation == token,
              try MobilePushRegistrationStore(directory: directory).registrations == registrations else {
            throw CancellationError()
        }
        try publish(NeedsYouSnapshot(servers: parts), now: now)
        return previous
    }

    /// A server's part, or its last one out of date when it can't be reached within 10 seconds.
    private func part(serverURL: String, session: URLSession, now: Date) async throws -> NeedsYouSnapshot.Server {
        do {
            return try await withThrowingTaskGroup(of: NeedsYouSnapshot.Server.self) { group in
                group.addTask { try await self.fetchedPart(serverURL: serverURL, session: session) }
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
            return .offline(serverURL, in: previous, at: now)
        }
    }

    private func fetchedPart(serverURL: String, session: URLSession) async throws -> NeedsYouSnapshot.Server {
        let catalog = ChannelCatalogStore(api: try ChannelAPI(serverURL: serverURL, session: session))
        await catalog.refresh()
        try Task.checkCancellation()
        if let failure = catalog.phase.failure { throw failure }
        return try part(of: catalog, serverURL: serverURL)
    }

    private func part(of catalog: ChannelCatalogStore, serverURL: String) throws -> NeedsYouSnapshot.Server {
        guard catalog.state != nil else { throw ChannelAPIError.invalidResponse }
        let waiting = catalog.waitingRequests()
        for entry in waiting {
            guard entry.sequence < Int.max, ChannelWaitingRequest.Identity(
                serverURL: serverURL, channelID: entry.channel.id, sequence: entry.sequence
            ) != nil else { throw ChannelAPIError.invalidMessage("A waiting request has an invalid sequence.") }
        }
        return .init(serverURL: serverURL, updatedAt: .now, isOffline: false, isAvailable: true, waiting: waiting)
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
