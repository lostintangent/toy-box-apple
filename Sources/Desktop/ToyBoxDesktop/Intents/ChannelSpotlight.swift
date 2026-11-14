import AppIntents
import AppKit
import ToyBoxClient
import ToyBoxKit
import CoreSpotlight
import SwiftUI
import ToyBoxUI

/// Keeps Spotlight's channels in step with the servers saved in Settings. Each channel appears by
/// name, with its purpose and its avatar, and picking one runs Open Channel. A deleted
/// channel leaves, and so does every channel of a server you remove.
@MainActor
final class ChannelSpotlight {
    /// What Spotlight knows about a channel.
    struct Entry: Equatable, Sendable {
        let target: ChannelTarget
        let name: String
        let purpose: String?
        let avatar: ChannelAvatar?
        var id: String { target.identifier }

        init(_ target: ChannelTarget, name: String, purpose: String? = nil, avatar: ChannelAvatar? = nil) {
            self.target = target
            self.name = name
            self.purpose = purpose
            self.avatar = avatar
        }

        init(_ listed: ChannelIntents.Listed) {
            self.init(listed.target, name: listed.channel.name, purpose: listed.channel.purposePreview,
                      avatar: listed.channel.avatar)
        }
    }

    /// The channels Spotlight should hold, nil until a server's catalog has loaded and every other
    /// has loaded or failed.
    struct Catalog: Equatable {
        var channels: [Entry]?
    }

    /// What Spotlight holds, by channel.
    struct Indexed: Equatable {
        var entries: [String: Entry]
    }

    /// The changes that bring Spotlight to a catalog, applied in this order.
    struct Plan: Equatable {
        var removesAll = false
        var removes: [String] = []
        var indexes: [Entry] = []

        var isEmpty: Bool { !removesAll && removes.isEmpty && indexes.isEmpty }
    }

    /// Spotlight's index for the app, or a fake in tests.
    struct Index: Sendable {
        var add: @Sendable ([ChannelEntity]) async throws -> Void
        var remove: @Sendable ([String]) async throws -> Void
        var removeAll: @Sendable () async throws -> Void

        static let spotlight = Index(
            add: { try await CSSearchableIndex.default().indexAppEntities($0) },
            remove: { try await CSSearchableIndex.default().deleteAppEntities(identifiedBy: $0, ofType: ChannelEntity.self) },
            removeAll: { try await CSSearchableIndex.default().deleteAppEntities(ofType: ChannelEntity.self) }
        )
    }

    private let index: Index
    private let icon: @MainActor (Entry) async -> Data?
    /// Nil until the app replaces whatever an earlier launch left, or after Spotlight fails.
    private(set) var indexed: Indexed?
    private var latest: Catalog?
    private var tail: Task<Void, Never>?

    init(index: Index = .spotlight, icon: @escaping @MainActor (Entry) async -> Data? = ChannelSpotlight.renderIcon) {
        self.index = index
        self.icon = icon
    }

    /// Only the server saved in Settings fills Spotlight. A `--server` or `TOY_BOX_SERVER_URL`
    /// launch is session-only, so a test against a demo never replaces your channels.
    static func indexes(_ options: LaunchOptions,
                        bundleID: String? = Bundle.main.bundleIdentifier,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        bundleID == "dev.toybox.desktop" && options.allowsUserIntegrations(environment: environment)
    }

    /// Follows the app's servers and catalogs for as long as the app runs.
    func observe(_ model: AppModel) {
        let catalog = withObservationTracking {
            Catalog(model.catalogs)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe(model) }
        }
        update(catalog)
    }

    func update(_ catalog: Catalog) {
        latest = catalog
        let (plan, next) = Self.plan(from: indexed, to: catalog)
        indexed = next
        apply(plan)
    }

    /// Replaces everything Spotlight holds with the latest catalog, or only the named channels.
    func reindex(_ ids: [String]? = nil) async {
        if let ids, let indexed {
            apply(Plan(removes: ids.filter { indexed.entries[$0] == nil },
                       indexes: ids.compactMap { indexed.entries[$0] }))
        } else {
            indexed = nil
            if let latest { update(latest) }
        }
        await tail?.value
    }

    /// Waits for every change so far to reach Spotlight.
    func settle() async {
        await tail?.value
    }

    static func plan(from indexed: Indexed?, to catalog: Catalog) -> (plan: Plan, indexed: Indexed?) {
        var seen: Set<String> = []
        let channels = (catalog.channels ?? []).filter { seen.insert($0.id).inserted }
        let entries = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
        // An earlier launch's channels stay until the catalogs arrive, and what's indexed stays
        // while a server you add loads.
        guard catalog.channels != nil else { return (Plan(), indexed) }
        guard let indexed else {
            return (Plan(removesAll: true, indexes: channels), Indexed(entries: entries))
        }
        return (Plan(removes: indexed.entries.keys.filter { entries[$0] == nil }.sorted(),
                     indexes: channels.filter { indexed.entries[$0.id] != $0 }),
                Indexed(entries: entries))
    }

    /// Applies changes one batch at a time, in order.
    private func apply(_ plan: Plan) {
        guard !plan.isEmpty else { return }
        let previous = tail
        let index = index
        let icon = icon
        tail = Task { [weak self] in
            await previous?.value
            var entities: [ChannelEntity] = []
            for entry in plan.indexes {
                entities.append(ChannelEntity(entry.target, name: entry.name, purpose: entry.purpose,
                                              thumbnail: await icon(entry)))
            }
            do {
                if plan.removesAll { try await index.removeAll() }
                if !plan.removes.isEmpty { try await index.remove(plan.removes) }
                if !entities.isEmpty { try await index.add(entities) }
            } catch {
                // What Spotlight holds is unknown now, so the next change replaces all of it.
                self?.indexed = nil
            }
        }
    }

    static func renderIcon(_ entry: Entry) async -> Data? {
        await renderIcon(entry.avatar, api: try? ChannelAPI(serverURL: entry.target.serverURL))
    }

    /// A channel's avatar at Spotlight's size, as PNG data. An image loads first, since a renderer
    /// draws only what's already there, and one that can't load draws the #.
    static func renderIcon(_ avatar: ChannelAvatar?, api: ChannelAPI?) async -> Data? {
        if case .image(let address)? = avatar, let api { await ChannelAvatarImages.shared.load(address, api: api) }
        let renderer = ImageRenderer(content: ChannelMark(avatar, api: api, size: 64))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

extension ChannelSpotlight.Catalog {
    @MainActor
    init(_ catalogs: [ChannelCatalogStore]) {
        self.init(channels: ChannelIntents.Listed.spotlight(in: catalogs)?.map(ChannelSpotlight.Entry.init))
    }
}
