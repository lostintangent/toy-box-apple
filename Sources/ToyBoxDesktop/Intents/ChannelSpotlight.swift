import AppIntents
import AppKit
import ChannelKit
import CoreSpotlight
import SwiftUI
import ToyBoxUI

/// Keeps Spotlight's channels in step with the server saved in Settings. Each channel appears by
/// name, with its purpose and the sidebar's icon, and picking one runs Open Channel. A deleted
/// channel leaves, and switching servers takes every channel out until the new server's arrive.
@MainActor
final class ChannelSpotlight {
    /// What Spotlight knows about a channel.
    struct Entry: Equatable, Sendable {
        let id: String
        let name: String
        let purpose: String?

        init(id: String, name: String, purpose: String? = nil) {
            self.id = id
            self.name = name
            self.purpose = purpose
        }

        init(_ channel: Channel) {
            self.init(id: channel.id, name: channel.name, purpose: channelPurposePreview(channel.purpose))
        }
    }

    /// The channels Spotlight should hold. `server` is nil when the app has no valid server, and
    /// `channels` is nil until that server's catalog arrives.
    struct Catalog: Equatable {
        var server: String?
        var channels: [Entry]?
    }

    /// What Spotlight holds, by channel.
    struct Indexed: Equatable {
        var server: String?
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
    private let icon: @MainActor () -> Data?
    private lazy var thumbnail = icon()
    /// Nil until the app replaces whatever an earlier launch left, or after Spotlight fails.
    private(set) var indexed: Indexed?
    private var latest: Catalog?
    private var tail: Task<Void, Never>?

    init(index: Index = .spotlight, icon: @escaping @MainActor () -> Data? = ChannelSpotlight.renderIcon) {
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

    /// Follows the app's server and catalog for as long as the app runs.
    func observe(_ model: AppModel) {
        let catalog = withObservationTracking {
            Catalog(model)
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
        guard let indexed, indexed.server == catalog.server else {
            // A saved server's channels from an earlier launch stay until its catalog arrives,
            // but another server's leave at once.
            if indexed == nil, catalog.server != nil, catalog.channels == nil { return (Plan(), nil) }
            return (Plan(removesAll: indexed?.entries.isEmpty != true, indexes: channels),
                    Indexed(server: catalog.server, entries: entries))
        }
        guard catalog.channels != nil else { return (Plan(), indexed) }
        return (Plan(removes: indexed.entries.keys.filter { entries[$0] == nil }.sorted(),
                     indexes: channels.filter { indexed.entries[$0.id] != $0 }),
                Indexed(server: catalog.server, entries: entries))
    }

    /// Applies changes one batch at a time, in order.
    private func apply(_ plan: Plan) {
        guard !plan.isEmpty else { return }
        let thumbnail = plan.indexes.isEmpty ? nil : thumbnail
        let entities = plan.indexes.map { entry in
            ChannelEntity(id: entry.id, name: entry.name, purpose: entry.purpose, thumbnail: thumbnail)
        }
        let previous = tail
        let index = index
        tail = Task { [weak self] in
            await previous?.value
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

    /// The sidebar's channel icon at Spotlight's size, as PNG data.
    static func renderIcon() -> Data? {
        let renderer = ImageRenderer(content: ChannelSpotlightIcon())
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

extension ChannelSpotlight.Catalog {
    @MainActor
    init(_ model: AppModel) {
        guard let catalog = model.catalog else {
            self.init(server: nil, channels: nil)
            return
        }
        self.init(server: model.serverURL,
                  channels: catalog.hasLoaded ? catalog.channels.map(ChannelSpotlight.Entry.init) : nil)
    }
}

/// The sidebar's channel icon, drawn larger.
private struct ChannelSpotlightIcon: View {
    private static let size: CGFloat = 64

    var body: some View {
        Image(systemName: "number")
            // The sidebar's 14-point mark in its 30-point circle.
            .font(.system(size: Self.size * 14 / 30, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Self.size, height: Self.size)
            .background(Circle().fill(ChannelSidebarRow.cyan.gradient))
    }
}
