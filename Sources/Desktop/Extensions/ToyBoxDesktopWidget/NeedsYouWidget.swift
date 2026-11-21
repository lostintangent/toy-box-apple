import ToyBoxKit
import SwiftUI
import ToyBoxWidgetViews
import WidgetKit

struct NeedsYouProvider: TimelineProvider {
    func placeholder(in context: Context) -> NeedsYouEntry { .init(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (NeedsYouEntry) -> Void) {
        completion(.init(date: .now, snapshot: WidgetSnapshotReader.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NeedsYouEntry>) -> Void) {
        completion(NeedsYouEntry.timeline(snapshot: WidgetSnapshotReader.load(), now: .now))
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
