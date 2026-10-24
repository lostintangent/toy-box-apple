import ChannelKit
import Foundation
import Observation

@MainActor @Observable
final class QuickSendTargetHistory {
    private struct Saved: Codable {
        var lastChosenID: String?
        var draftTargetID: String?
        var recents: [String] = []
        var names: [String: String] = [:]
    }

    private var saved = Saved()
    private(set) var selectedID: String?
    private(set) var error: String?
    private let defaults: UserDefaults
    private let key: String

    init(serverURL: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "quickSend.channels." + ComposerDraft.storageKey(serverURL: serverURL, channelID: "", scope: .quickSend)
        if let data = defaults.data(forKey: key) {
            do { saved = try JSONDecoder().decode(Saved.self, from: data) }
            catch { self.error = "Saved Quick Send channel choices could not be restored: \(error.localizedDescription)" }
        }
    }

    func initialTarget(channels: [Channel], lastUsedID: String?, catalogLoaded: Bool = true,
                       hasDraft: (String) -> Bool) -> String? {
        if let id = saved.draftTargetID, hasDraft(id) { return id }
        if let id = saved.lastChosenID {
            return !catalogLoaded || hasDraft(id) || channels.contains { $0.id == id } ? id : nil
        }
        if let lastUsedID, channels.contains(where: { $0.id == lastUsedID }) { return lastUsedID }
        return channels.count == 1 ? channels.first?.id : nil
    }

    func name(for id: String) -> String? { saved.names[id] }

    func restoreTarget(channels: [Channel], lastUsedID: String?, catalogLoaded: Bool,
                       hasDraft: (String) -> Bool) {
        selectedID = initialTarget(channels: channels, lastUsedID: lastUsedID,
                                   catalogLoaded: catalogLoaded, hasDraft: hasDraft)
    }

    func choose(_ channel: Channel) {
        selectedID = channel.id
        saved.lastChosenID = channel.id
        saved.recents.removeAll { $0 == channel.id }
        saved.recents.insert(channel.id, at: 0)
        saved.recents = Array(saved.recents.prefix(20))
        saved.names[channel.id] = channel.name
        save()
    }

    func trackDraft(channelID: String, name: String?, hasContent: Bool) {
        if hasContent {
            saved.draftTargetID = channelID
            if let name { saved.names[channelID] = name }
        } else if saved.draftTargetID == channelID {
            saved.draftTargetID = nil
        } else { return }
        save()
    }

    func choices(channels: [Channel], query: String) -> [Channel] {
        let matching = channels.filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
                || $0.purpose?.localizedStandardContains(query) == true
                || $0.directory?.localizedStandardContains(query) == true
        }
        let recent = saved.recents.prefix(3).compactMap { id in matching.first { $0.id == id } }
        let recentIDs = Set(recent.map(\.id))
        return recent + matching.filter { !recentIDs.contains($0.id) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(saved), forKey: key)
            error = nil
        } catch { self.error = "Quick Send channel choices could not be saved: \(error.localizedDescription)" }
    }
}
