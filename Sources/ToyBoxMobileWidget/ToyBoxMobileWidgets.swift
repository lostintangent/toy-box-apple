import OSLog
import SwiftUI
import ToyBoxMobileIntegrations
import WidgetKit

@main
struct ToyBoxMobileWidgets: WidgetBundle {
    var body: some Widget {
        FoundationWidget()
        #if DEBUG && targetEnvironment(simulator)
        FoundationActivityWidget()
        #endif
    }
}

private struct FoundationEntry: TimelineEntry {
    let date: Date
    let shared: String
}

private struct FoundationProvider: TimelineProvider {
    func placeholder(in context: Context) -> FoundationEntry { .init(date: .now, shared: "Placeholder") }

    func getSnapshot(in context: Context, completion: @escaping (FoundationEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FoundationEntry>) -> Void) {
        completion(.init(entries: [entry()], policy: .never))
    }

    private func entry() -> FoundationEntry {
        #if DEBUG && targetEnvironment(simulator)
        do {
            let marker = try MobileFoundationProbe.record("widget")
            return .init(date: .now, shared: "Shared: \(marker.prefix(8))")
        } catch {
            Logger(subsystem: "dev.toybox.mobile.widget", category: "Foundation")
                .error("Shared-container probe failed: \(error.localizedDescription, privacy: .public)")
            return .init(date: .now, shared: "Shared container unavailable")
        }
        #else
        return .init(date: .now, shared: "Coming in Release 2")
        #endif
    }
}

private struct FoundationWidget: Widget {
    let kind = "ToyBoxMobileFoundation"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FoundationProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                Label("Toy Box", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Text("Needs You").font(.title3)
                Text(entry.shared).font(.caption).foregroundStyle(.secondary)
            }
            .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Toy Box Foundation")
        .description("A placeholder for the Release 2 Needs You widget.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#if DEBUG && targetEnvironment(simulator)
import ActivityKit

private struct FoundationActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FoundationActivity.self) { context in
            HStack {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                VStack(alignment: .leading) {
                    Text("Toy Box foundation").font(.headline)
                    Text("Local update \(context.state.update)")
                }
                Spacer()
                Text(context.attributes.marker.prefix(8)).font(.caption.monospaced())
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                }
                DynamicIslandExpandedRegion(.trailing) { Text("\(context.state.update)") }
                DynamicIslandExpandedRegion(.bottom) { Text("Toy Box foundation · local update") }
            } compactLeading: {
                Image(systemName: "bubble.left.and.bubble.right.fill")
            } compactTrailing: {
                Text("\(context.state.update)")
            } minimal: {
                Image(systemName: "bubble.left.fill")
            }
        }
    }
}
#endif
