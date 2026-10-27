import SwiftUI
import ToyBoxMobileIntegrations
import WidgetKit

@main
struct ToyBoxMobileWidgets: WidgetBundle {
    var body: some Widget {
        MobileNeedsYouWidget()
        #if DEBUG && targetEnvironment(simulator)
        FoundationActivityWidget()
        #endif
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
