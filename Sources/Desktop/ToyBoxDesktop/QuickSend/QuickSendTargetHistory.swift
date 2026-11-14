import ToyBoxKit
import ToyBoxClient
import Foundation
import Observation

/// Where Quick Send starts and the order its chooser lists channels, across every server.
@MainActor @Observable
final class QuickSendTargetHistory {
    /// A channel on its server.
    struct Choice: Identifiable, Equatable {
        let target: ChannelTarget
        let channel: Channel
        var id: ChannelTarget { target }
    }

    private struct Saved: Codable {
        var lastChosen: ChannelTarget?
        var draftTarget: ChannelTarget?
        var recents: [ChannelTarget] = []
        /// Each channel's name by its target's identifier.
        var names: [String: String] = [:]
    }

    static let key = "quickSend.targets"
    private var saved = Saved()
    private(set) var selected: ChannelTarget?
    private(set) var error: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            do { saved = try JSONDecoder().decode(Saved.self, from: data) }
            catch { self.error = "Saved Quick Send channel choices could not be restored: \(error.localizedDescription)" }
        }
    }

    /// An unfinished Quick Send draft, then the last channel chosen here, the last main-window
    /// channel or the only channel. A channel on a server that's gone is never one.
    func initialTarget(in catalogs: [ChannelCatalogStore], lastUsed: ChannelTarget?,
                       hasDraft: (ChannelTarget) -> Bool) -> ChannelTarget? {
        // Whether its server lists a channel, or nil until that server's catalog loads.
        func lists(_ target: ChannelTarget) -> Bool? {
            guard let catalog = catalogs.first(at: target.serverURL) else { return false }
            return catalog.isLoaded ? catalog.channels.contains { $0.id == target.channelID } : nil
        }
        func drafted(_ target: ChannelTarget) -> Bool { catalogs.first(at: target.serverURL) != nil && hasDraft(target) }
        if let target = saved.draftTarget, drafted(target) { return target }
        if let target = saved.lastChosen { return lists(target) != false || drafted(target) ? target : nil }
        if let lastUsed, lists(lastUsed) == true { return lastUsed }
        guard catalogs.allSatisfy(\.isLoaded) else { return nil }
        let all = catalogs.flatMap { catalog in catalog.channels.compactMap { catalog.target($0.id) } }
        return all.count == 1 ? all.first : nil
    }

    func name(for target: ChannelTarget) -> String? { saved.names[target.identifier] }

    func restoreTarget(in catalogs: [ChannelCatalogStore], lastUsed: ChannelTarget?,
                       hasDraft: (ChannelTarget) -> Bool) {
        selected = initialTarget(in: catalogs, lastUsed: lastUsed, hasDraft: hasDraft)
    }

    func choose(_ choice: Choice) {
        selected = choice.target
        saved.lastChosen = choice.target
        saved.recents.removeAll { $0 == choice.target }
        saved.recents.insert(choice.target, at: 0)
        saved.recents = Array(saved.recents.prefix(20))
        saved.names[choice.target.identifier] = choice.channel.name
        save()
    }

    func trackDraft(_ target: ChannelTarget, name: String?, hasContent: Bool) {
        if hasContent {
            saved.draftTarget = target
            if let name { saved.names[target.identifier] = name }
        } else if saved.draftTarget == target {
            saved.draftTarget = nil
        } else { return }
        save()
    }

    /// Up to three recent channels across every server, then each server's others A to Z, which
    /// with one server is `choices(matching:recentIDs:)`.
    func choices(in catalogs: [ChannelCatalogStore], query: String) -> (recent: [Choice], others: [[Choice]]) {
        let recent = saved.recents.prefix(3).compactMap { target -> Choice? in
            let channel = catalogs.first(at: target.serverURL)?.channels.first { $0.id == target.channelID }
            return channel.flatMap { $0.matches(query) ? Choice(target: target, channel: $0) : nil }
        }
        return (recent, catalogs.map { catalog in
            let recentIDs = recent.compactMap { catalog.target($0.channel.id) == $0.target ? $0.channel.id : nil }
            return catalog.channels.choices(matching: query, recentIDs: recentIDs).others.compactMap { channel in
                catalog.target(channel.id).map { Choice(target: $0, channel: channel) }
            }
        })
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(saved), forKey: Self.key)
            error = nil
        } catch { self.error = "Quick Send channel choices could not be saved: \(error.localizedDescription)" }
    }
}
