import AppKit
import ChannelClient
import Foundation
import Observation

/// Whether a channel's folder, which is a path on the server, can be opened on this Mac.
enum ChannelFolderAvailability: Equatable, Sendable {
    case openable
    case remote(host: String)
    case missing
}

/// Caches folder availability per server host and path. Lookups never touch the disk once a key
/// is known, so they're safe in `body`. `refresh` re-checks every known folder and runs on catalog
/// loads and app activation.
@MainActor @Observable
final class ChannelFolders {
    private var revision = 0
    @ObservationIgnored private var cache: [Key: ChannelFolderAvailability] = [:]
    @ObservationIgnored private var localNames: Set<String>?
    @ObservationIgnored private var resolvingLocalNames = false

    private struct Key: Hashable {
        let host: String
        let path: String
    }

    func availability(path: String, server: URL) -> ChannelFolderAvailability {
        _ = revision
        let key = Key(host: Self.normalizedHost(server), path: path)
        if let cached = cache[key] { return cached }
        let value = resolve(key)
        cache[key] = value
        return value
    }

    func refresh(paths: [String], server: URL) {
        let host = Self.normalizedHost(server)
        recheck(Set(paths.lazy.filter { !$0.isEmpty }.map { Key(host: host, path: $0) }))
    }

    private func recheck(_ additions: Set<Key>) {
        var changed = false
        for key in Set(cache.keys).union(additions) {
            let value = resolve(key)
            if cache[key] != value {
                cache[key] = value
                changed = true
            }
        }
        if changed { revision += 1 }
    }

    /// Opens a Finder window showing the folder. Unlike `NSWorkspace.open`, this never launches a
    /// package such as an app bundle that a server reports as its directory.
    func open(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Self.localPath(path))
    }

    func open(_ path: String, with application: URL) {
        NSWorkspace.shared.open([URL(fileURLWithPath: Self.localPath(path), isDirectory: true)],
                                withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    func copy(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    struct Application: Identifiable {
        let url: URL
        let name: String
        let icon: NSImage
        let isDefault: Bool
        var id: URL { url }
    }

    /// Apps that can open the folder: the default first, then the rest alphabetically.
    func applications(for path: String) -> [Application] {
        let folder = URL(fileURLWithPath: Self.localPath(path), isDirectory: true)
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: folder)?.standardizedFileURL
        var seen = Set<URL>()
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: folder).compactMap { url -> Application? in
            let url = url.standardizedFileURL
            guard seen.insert(url).inserted else { return nil }
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return Application(url: url, name: name, icon: icon, isDefault: url == defaultApp)
        }
        let others = apps.filter { !$0.isDefault }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return apps.filter(\.isDefault) + others
    }

    private func resolve(_ key: Key) -> ChannelFolderAvailability {
        if !Self.isLoopback(key.host) {
            guard let localNames else {
                resolveLocalNames()
                return .remote(host: key.host)
            }
            guard localNames.contains(key.host) else { return .remote(host: key.host) }
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: Self.localPath(key.path), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? .openable : .missing
    }

    /// `Host.current()` can block on DNS, so this Mac's names resolve once, off the main actor,
    /// and only when a server isn't a loopback address.
    private func resolveLocalNames() {
        guard !resolvingLocalNames else { return }
        resolvingLocalNames = true
        Task {
            let names = await Task.detached(priority: .utility) {
                let host = Host.current()
                return Set((host.names + host.addresses).map { $0.lowercased() })
            }.value
            localNames = Set(names.compactMap(Self.trimmedHost))
            recheck([])
        }
    }

    nonisolated static func isLoopback(_ host: String) -> Bool {
        isLoopbackHost(host)
    }

    nonisolated static func normalizedHost(_ server: URL) -> String {
        trimmedHost(server.host ?? "") ?? ""
    }

    nonisolated private static func trimmedHost(_ host: String) -> String? {
        let trimmed = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func localPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
