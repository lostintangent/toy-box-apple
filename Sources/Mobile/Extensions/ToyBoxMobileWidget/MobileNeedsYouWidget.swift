import ChannelKit
import OSLog
import SwiftUI
import ToyBoxMobileIntegrations
import ToyBoxWidgetViews
import WidgetKit

struct MobileNeedsYouWidget: Widget {
    let kind = NeedsYouSnapshot.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MobileNeedsYouProvider()) { entry in
            MobileNeedsYouWidgetContent(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Toy Box")
        .description("See which channels need your attention.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct MobileNeedsYouProvider: TimelineProvider {
    func placeholder(in context: Context) -> NeedsYouEntry {
        .init(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (NeedsYouEntry) -> Void) {
        completion(.init(date: .now, snapshot: MobileWidgetSnapshotReader.load()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<NeedsYouEntry>) -> Void) {
        Task { @MainActor in
            let snapshot: NeedsYouSnapshot?
            do {
                let publisher = try MobileWidgetSnapshotPublisher(reload: {})
                snapshot = try await publisher.refresh()
            } catch {
                Logger(subsystem: "dev.toybox.mobile.widget", category: "Snapshot")
                    .error("Could not refresh the widget timeline: \(error.localizedDescription, privacy: .public)")
                snapshot = MobileWidgetSnapshotReader.load()
            }
            completion(Self.timeline(snapshot: snapshot, now: .now))
        }
    }

    static func timeline(snapshot: NeedsYouSnapshot?, now: Date) -> Timeline<NeedsYouEntry> {
        var entries = [NeedsYouEntry(date: now, snapshot: snapshot)]
        if let snapshot, snapshot.isAvailable, !snapshot.isStale(at: now) {
            entries.append(.init(
                date: snapshot.updatedAt.addingTimeInterval(NeedsYouSnapshot.freshnessInterval),
                snapshot: snapshot))
        }
        return .init(entries: entries, policy: .after(now.addingTimeInterval(15 * 60)))
    }
}

enum MobileWidgetSnapshotReader {
    private static let logger = Logger(subsystem: "dev.toybox.mobile.widget", category: "Snapshot")

    static func load() -> NeedsYouSnapshot? {
        do {
            let file = try MobileSharedContainer.url().appending(path: NeedsYouSnapshot.fileName)
            let snapshot = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
            guard snapshot.version == 1 else {
                logger.error("The widget snapshot version is unsupported.")
                return nil
            }
            return snapshot
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            logger.error("Could not read the widget snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
