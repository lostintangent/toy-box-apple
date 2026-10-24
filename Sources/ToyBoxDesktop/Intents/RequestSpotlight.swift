import AppIntents
import AppKit
import ChannelKit
import CoreSpotlight
import Observation
import OSLog
import SwiftUI

@MainActor
final class RequestSpotlight {
    struct Catalog: Equatable {
        var server: String?
        /// Nil while the catalog loads. Unresolved questions join on a later observation.
        var entries: [WaitingRequestEntry]?

        init(server: String?, entries: [WaitingRequestEntry]?) {
            self.server = server
            self.entries = entries
        }

        @MainActor init(_ model: AppModel) {
            server = model.catalog == nil ? nil : WaitingRequestEntry.normalizedServer(model.serverURL)
            entries = model.catalog?.hasLoaded == true
                ? model.menuBarStatus.waiting.compactMap { WaitingRequestEntry(item: $0, serverURL: model.serverURL) }
                : nil
        }
    }

    struct Index: Sendable {
        var add: @Sendable ([WaitingRequestEntity]) async throws -> Void
        var remove: @Sendable ([String]) async throws -> Void
        var removeAll: @Sendable () async throws -> Void

        static let spotlight = Index(
            add: { try await CSSearchableIndex.default().indexAppEntities($0) },
            remove: { try await CSSearchableIndex.default().deleteAppEntities(identifiedBy: $0, ofType: WaitingRequestEntity.self) },
            removeAll: { try await CSSearchableIndex.default().deleteAppEntities(ofType: WaitingRequestEntity.self) }
        )
    }

    private let index: Index
    private let icon: @MainActor (ChannelAgent) -> Data?
    private let logger = Logger(subsystem: "dev.toybox.desktop", category: "SpotlightRequests")
    private var latest: Catalog?
    private var indexed: Catalog?
    private var tail: Task<Void, Never>?
    private var avatars: [String: (ChannelAgent, Data)] = [:]

    init(index: Index = .spotlight, icon: @escaping @MainActor (ChannelAgent) -> Data? = RequestSpotlight.renderAvatar) {
        self.index = index
        self.icon = icon
    }

    func observe(_ model: AppModel) {
        let catalog = withObservationTracking { Catalog(model) } onChange: { [weak self] in
            Task { @MainActor in self?.observe(model) }
        }
        update(catalog)
    }

    func update(_ catalog: Catalog) {
        guard latest != catalog || indexed == nil else { return }
        latest = catalog
        enqueue(catalog)
    }

    func reindex(_ identifiers: [String]?) async {
        guard let latest else { return }
        enqueue(latest, force: true, identifiers: identifiers)
        await settle()
    }

    func settle() async { await tail?.value }

    private func enqueue(_ catalog: Catalog, force: Bool = false, identifiers: [String]? = nil) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // Preserve the last launch's index until its first catalog arrives.
            guard indexed != nil || catalog.server == nil || catalog.entries != nil else { return }
            let changedServer = indexed?.server != catalog.server
            let replace = indexed == nil || changedServer || (force && identifiers == nil)
            if !replace && catalog.entries == nil { return }
            var seen = Set<String>()
            let entries = (catalog.entries ?? []).filter { seen.insert($0.id).inserted }
            let old = Dictionary((indexed?.entries ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let current = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let remove = (identifiers ?? Array(old.keys)).filter { current[$0] == nil }.sorted()
            let add = entries.filter { entry in
                replace || (force ? identifiers?.contains(entry.id) == true : old[entry.id] != entry)
            }
            do {
                if replace { try await index.removeAll() }
                else if !remove.isEmpty { try await index.remove(remove) }
                if !add.isEmpty { try await index.add(add.map(entity)) }
                indexed = Catalog(server: catalog.server, entries: entries)
            } catch {
                indexed = nil
                logger.error("Could not update waiting requests in Spotlight: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func entity(_ entry: WaitingRequestEntry) -> WaitingRequestEntity {
        if let cached = avatars[entry.agent.id], cached.0 == entry.agent {
            return WaitingRequestEntity(entry, thumbnail: cached.1)
        }
        let thumbnail = icon(entry.agent)
        if let thumbnail { avatars[entry.agent.id] = (entry.agent, thumbnail) }
        else { logger.error("Could not render a requester's Spotlight avatar.") }
        return WaitingRequestEntity(entry, thumbnail: thumbnail)
    }

    static func renderAvatar(_ agent: ChannelAgent) -> Data? {
        let renderer = ImageRenderer(content: AgentAvatarView(agent: agent, size: 64))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
