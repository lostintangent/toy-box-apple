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

    @ViewBuilder private var homeScreen: some View {
        switch state {
        case .waiting, .empty:
            ViewThatFits(in: .vertical) {
                ForEach(rowLimits, id: \.self) { limit in
                    NeedsYouWidgetContent(entry: entry, family: family,
                                          replyTargetSize: 44, maximumRequests: limit)
                }
            }
        case .stale, .notConnected:
            VStack(alignment: .leading, spacing: 8) {
                Text("Needs you").font(.system(size: 13, weight: .semibold)).widgetAccentable()
                Spacer(minLength: 0)
                Image(systemName: stateSymbol).font(.title2).foregroundStyle(.secondary)
                Text(stateTitle).font(.headline)
                if family != .systemSmall, state == .stale {
                    Text("Open Toy Box to refresh").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let snapshot = entry.snapshot, state == .stale {
                    Text("Last update \(snapshot.updatedAt, format: .dateTime.hour().minute())")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            Text("Needs you").font(.headline)
            switch state {
            case .waiting:
                if let snapshot = entry.snapshot {
                    Text(snapshot.waitingCount == 1 ? "1 channel" : "\(snapshot.waitingCount) channels")
                        .font(.subheadline)
                    Text("Updated \(snapshot.updatedAt, format: .dateTime.hour().minute())")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            case .empty:
                Text("Nothing needs you").font(.subheadline)
                if let snapshot = entry.snapshot {
                    Text("Updated \(snapshot.updatedAt, format: .dateTime.hour().minute())")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            case .stale:
                Text("May be out of date").font(.subheadline)
                if let snapshot = entry.snapshot {
                    Text("Last update \(snapshot.updatedAt, format: .dateTime.hour().minute())")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            case .notConnected:
                Text("Open Toy Box").font(.subheadline)
                Text("Open to connect").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateTitle: String {
        state == .stale ? "May be out of date" : "Open Toy Box to connect"
    }

    private var stateSymbol: String {
        state == .stale ? "clock" : "bubble.left.and.bubble.right"
    }
}
