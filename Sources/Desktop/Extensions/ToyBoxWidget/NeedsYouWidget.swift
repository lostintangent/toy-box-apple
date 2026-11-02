import ChannelKit
import SwiftUI
import ToyBoxWidgetViews
import WidgetKit

struct NeedsYouProvider: TimelineProvider {
    func placeholder(in context: Context) -> NeedsYouEntry { .init(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (NeedsYouEntry) -> Void) {
        completion(.init(date: .now, snapshot: WidgetSnapshotReader.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NeedsYouEntry>) -> Void) {
        let now = Date(), snapshot = WidgetSnapshotReader.load()
        var entries = [NeedsYouEntry(date: now, snapshot: snapshot)]
        if let snapshot, !snapshot.isStale(at: now) {
            entries.append(.init(date: snapshot.updatedAt.addingTimeInterval(NeedsYouSnapshot.freshnessInterval),
                                 snapshot: snapshot))
        }
        completion(.init(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct NeedsYouWidget: Widget {
    let kind = NeedsYouSnapshot.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NeedsYouProvider()) { entry in
            NeedsYouWidgetContent(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Toy Box")
        .description("See which channels need your attention.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
