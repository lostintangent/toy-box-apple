import ChannelKit
import Foundation
import Testing
@testable import ToyBoxMobileIntegrations

struct MobileWidgetSnapshotPublisherTests {
    @Test @MainActor func thePhoneSnapshotKeepsMacFreshnessAndCoalescesUnchangedWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var reloads = 0
        let publisher = try MobileWidgetSnapshotPublisher(directory: directory, avatarPNG: { _ in nil },
                                                          reload: { reloads += 1 })
        let now = Date(timeIntervalSince1970: 1793086200)
        let snapshot = Self.snapshot(now: now)
        let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        try publisher.publish(snapshot, now: now)
        #expect(try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file)) == snapshot)
        #expect(reloads == 1)
        try publisher.publish(snapshot, now: now.addingTimeInterval(10))
        #expect(reloads == 1)
        try publisher.publish(snapshot, now: now.addingTimeInterval(15 * 60))
        #expect(reloads == 2)
        let refreshed = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(refreshed.updatedAt == now.addingTimeInterval(15 * 60))
        #expect(!refreshed.isStale(at: refreshed.updatedAt.addingTimeInterval(30 * 60 - 1)))
        #expect(refreshed.isStale(at: refreshed.updatedAt.addingTimeInterval(30 * 60)))
    }

    @Test @MainActor func anOfflineRelaunchKeepsOnlyTheSelectedServersCachedRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try MobileWidgetSnapshotPublisher(directory: directory, avatarPNG: { _ in nil }, reload: {})
        let snapshot = Self.snapshot(now: .now)
        try first.publish(snapshot)
        let restored = try MobileWidgetSnapshotPublisher(directory: directory, avatarPNG: { _ in nil }, reload: {})
        try await restored.update(catalog: nil, serverURL: snapshot.serverURL)
        let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        let cached = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(cached.isOffline)
        #expect(cached.isAvailable)
        #expect(cached.requests == snapshot.requests)
        try await restored.update(catalog: nil, serverURL: "https://other.test")
        let switched = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(switched.serverURL == "https://other.test")
        #expect(!switched.isAvailable)
        #expect(switched.waitingCount == 0)
        #expect(switched.requests.isEmpty)
    }

    @Test @MainActor func offlineUpdatesKeepTheCachedObservationTimeWithoutAHeartbeatRewrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var reloads = 0
        let now = Date(timeIntervalSince1970: 1793086200)
        let snapshot = Self.snapshot(now: now)
        let publisher = try MobileWidgetSnapshotPublisher(
            directory: directory, avatarPNG: { _ in nil }, reload: { reloads += 1 })
        try publisher.publish(snapshot, now: now)
        #expect(reloads == 1)

        try await publisher.update(catalog: nil, serverURL: snapshot.serverURL)
        let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        let cached = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(cached.isOffline)
        #expect(cached.isAvailable)
        #expect(cached.updatedAt == now)
        #expect(cached.requests == snapshot.requests)
        #expect(reloads == 2)
        let fileNumber = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)

        try await publisher.update(catalog: nil, serverURL: snapshot.serverURL)
        let repeated = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(repeated == cached)
        #expect(reloads == 2)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber == fileNumber)
    }

    private static func snapshot(now: Date) -> NeedsYouSnapshot {
        NeedsYouSnapshot(
            serverURL: "https://server.test", updatedAt: now, isOffline: false, isAvailable: true,
            waitingCount: 1, requests: [.init(channelID: "studio", channelName: "Studio", sequence: 15,
                                            quote: "Ready to ship?", agentName: "Lead", requestedAt: now,
                                            avatarPNG: Data([1, 2, 3]))]
        )
    }
}
