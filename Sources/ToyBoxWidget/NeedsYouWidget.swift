import AppKit
import ChannelKit
import OSLog
import SwiftUI
import WidgetKit

struct NeedsYouProvider: TimelineProvider {
    private let logger = Logger(subsystem: "dev.toybox.desktop.widget", category: "Snapshot")

    func placeholder(in context: Context) -> NeedsYouEntry { .init(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (NeedsYouEntry) -> Void) {
        completion(.init(date: .now, snapshot: load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NeedsYouEntry>) -> Void) {
        let now = Date(), snapshot = load()
        var entries = [NeedsYouEntry(date: now, snapshot: snapshot)]
        if let snapshot, !snapshot.isStale(at: now) {
            entries.append(.init(date: snapshot.updatedAt.addingTimeInterval(NeedsYouSnapshot.freshnessInterval),
                                 snapshot: snapshot))
        }
        completion(.init(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }

    private func load() -> NeedsYouSnapshot? {
        guard Bundle.main.object(forInfoDictionaryKey: NeedsYouSnapshot.groupInfoKey) as? String == NeedsYouSnapshot.appGroup,
              let directory = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: NeedsYouSnapshot.appGroup
              ) else {
            logger.error("The widget has no accessible app group.")
            return nil
        }
        do {
            let snapshot = try JSONDecoder().decode(NeedsYouSnapshot.self,
                from: Data(contentsOf: directory.appendingPathComponent(NeedsYouSnapshot.fileName)))
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

@main
struct NeedsYouWidget: Widget {
    let kind = NeedsYouSnapshot.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NeedsYouProvider()) { entry in
            NeedsYouWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Needs you")
        .description("Requests from your teams that are waiting for a reply.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NeedsYouWidgetView: View {
    let entry: NeedsYouEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        NeedsYouWidgetContent(entry: entry, family: family)
    }
}
