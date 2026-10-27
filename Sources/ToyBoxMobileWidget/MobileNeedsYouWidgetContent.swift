import ChannelKit
import SwiftUI
import ToyBoxWidgetViews
import WidgetKit

enum MobileNeedsYouState: Equatable {
    case waiting, empty, stale, notConnected

    init(entry: NeedsYouEntry) {
        guard let snapshot = entry.snapshot, snapshot.isAvailable else {
            self = .notConnected
            return
        }
        self = snapshot.isStale(at: entry.date) ? .stale : snapshot.waitingCount == 0 ? .empty : .waiting
    }
}

struct MobileNeedsYouWidgetContent: View {
    let entry: NeedsYouEntry
    @Environment(\.widgetFamily) private var family

    private var state: MobileNeedsYouState { .init(entry: entry) }

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                lockScreen
            } else {
                homeScreen
            }
        }
        .widgetURL(destination)
    }

    private var homeScreen: some View {
        ViewThatFits(in: .vertical) {
            ForEach(rowLimits, id: \.self) { limit in
                NeedsYouWidgetContent(entry: entry, family: family,
                                      replyTargetSize: 44, maximumRequests: limit)
            }
        }
    }

    private var rowLimits: [Int] {
        switch family {
        case .systemLarge: [5, 4, 3, 2, 1]
        case .systemMedium: [2, 1]
        default: [1]
        }
    }

    private var destination: URL {
        guard family == .systemSmall, state == .waiting,
              let snapshot = entry.snapshot, let request = snapshot.requests.first else {
            return NeedsYouSnapshot.mainURL
        }
        return NeedsYouRequestLink(serverURL: snapshot.serverURL, channelID: request.channelID,
                                   sequence: request.sequence).url ?? NeedsYouSnapshot.mainURL
    }

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch state {
            case .waiting:
                if let snapshot = entry.snapshot {
                    Text(snapshot.waitingCount == 1
                         ? "1 channel needs you" : "\(snapshot.waitingCount) channels need you")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .empty:
                NeedsYouEmptyState()
            case .stale:
                Text("May be out of date").font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let snapshot = entry.snapshot {
                    Text("Last update \(snapshot.updatedAt, format: .dateTime.hour().minute())")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            case .notConnected:
                Text("Open Toy Box to connect").font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
