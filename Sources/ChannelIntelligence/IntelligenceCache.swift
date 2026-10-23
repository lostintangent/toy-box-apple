import CryptoKit
import Foundation

/// A small least-recently-used map.
struct LRUCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    let limit: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int { values.count }

    mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func set(_ value: Value, for key: Key) {
        values[key] = value
        touch(key)
        while order.count > limit {
            values.removeValue(forKey: order.removeFirst())
        }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// Alt text by attachment, in memory and in Caches, with a byte cap on disk. Entries without text
/// record images the model couldn't describe, so they aren't retried.
actor AltTextStore {
    struct Entry: Codable, Sendable, Hashable {
        let text: String?
    }

    static let defaultDirectory = URL.cachesDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "ToyBoxDesktop", directoryHint: .isDirectory)
        .appending(path: "AltText", directoryHint: .isDirectory)

    let directory: URL
    let byteLimit: Int
    private var memory: LRUCache<String, Entry>
    private var diskBytes: Int?

    init(directory: URL = AltTextStore.defaultDirectory, byteLimit: Int = 2_000_000, memoryLimit: Int = 512) {
        self.directory = directory
        self.byteLimit = byteLimit
        memory = LRUCache(limit: memoryLimit)
    }

    func entry(for key: String) -> Entry? {
        if let entry = memory.value(for: key) { return entry }
        guard let data = try? Data(contentsOf: file(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        memory.set(entry, for: key)
        return entry
    }

    func store(_ entry: Entry, for key: String) {
        memory.set(entry, for: key)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = file(for: key)
            let previous = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try data.write(to: url, options: .atomic)
            diskBytes = (diskBytes ?? measure()) - previous + data.count
            if let bytes = diskBytes, bytes > byteLimit { trim() }
        } catch {
            return
        }
    }

    private func file(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest + ".json", directoryHint: .notDirectory)
    }

    private func files() -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "json", let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    private func measure() -> Int {
        files().reduce(0) { $0 + $1.size }
    }

    /// Removes the oldest entries until the cache is at three quarters of its cap.
    private func trim() {
        var bytes = measure()
        for file in files().sorted(by: { $0.date < $1.date }) where bytes > byteLimit * 3 / 4 {
            try? FileManager.default.removeItem(at: file.url)
            bytes -= file.size
        }
        diskBytes = bytes
    }
}
