import ActivityKit
import ChannelKit
import SwiftUI
import WidgetKit

struct ChannelActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChannelActivityAttributes.self) { context in
            ChannelActivityLockScreenContent(context: context)
                .widgetURL(Self.destination(context))
        } dynamicIsland: { context in
            let presentation = ChannelActivityPresentation(state: context.state, isStale: context.isStale)
            let content = ChannelActivityContent(channelName: context.attributes.channelName,
                                                 presentation: presentation)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    content.heading
                }
                DynamicIslandExpandedRegion(.bottom) {
                    content.summary
                }
            } compactLeading: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .accessibilityLabel(context.attributes.channelName)
            } compactTrailing: {
                if let symbol = presentation.compactSymbol {
                    Image(systemName: symbol).accessibilityLabel(presentation.headline)
                } else {
                    Text(context.state.workingAgents.count, format: .number)
                        .monospacedDigit()
                        .accessibilityLabel(presentation.headline)
                }
            } minimal: {
                Image(systemName: presentation.minimalSymbol)
                    .accessibilityLabel(presentation.headline)
            }
            .widgetURL(Self.destination(context))
        }
        .supplementalActivityFamilies([.small])
    }

    private static func destination(_ context: ActivityViewContext<ChannelActivityAttributes>) -> URL? {
        let presentation = ChannelActivityPresentation(state: context.state, isStale: context.isStale)
        return ChannelActivityLink(channelID: context.attributes.channelID,
                                   registrationID: context.attributes.registrationID,
                                   sequence: presentation.requestSequence).url
    }
}

private struct ChannelActivityLockScreenContent: View {
    let context: ActivityViewContext<ChannelActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        ChannelActivityContent(channelName: context.attributes.channelName,
                               presentation: .init(state: context.state, isStale: context.isStale))
            .padding(family == .small ? 12 : 16)
    }
}
