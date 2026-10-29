import ChannelKit
import SwiftUI
import WidgetKit

package struct NeedsYouEntry: TimelineEntry {
    package var date: Date
    package var snapshot: NeedsYouSnapshot?

    package init(date: Date, snapshot: NeedsYouSnapshot? = nil) {
        self.date = date
        self.snapshot = snapshot
    }
}

package struct NeedsYouWidgetContent: View {
    let entry: NeedsYouEntry
    let replyTargetSize: CGFloat
    let maximumRequests: Int?
    @Environment(\.widgetFamily) private var family

    package init(entry: NeedsYouEntry, replyTargetSize: CGFloat = 28, maximumRequests: Int? = nil) {
        self.entry = entry
        self.replyTargetSize = replyTargetSize
        self.maximumRequests = maximumRequests
    }

    private var limit: Int {
        min(maximumRequests ?? 5, family == .systemSmall ? 1 : family == .systemMedium ? 2 : 5)
    }
    private var snapshot: NeedsYouSnapshot? { entry.snapshot.flatMap { $0.isAvailable ? $0 : nil } }

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot {
                if snapshot.isStale(at: entry.date) {
                    status(title: "May be out of date", symbol: "clock", lastUpdate: snapshot.updatedAt)
                } else if snapshot.waitingCount == 0 {
                    NeedsYouEmptyState()
                } else {
                    VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 8) {
                        ForEach(Array(snapshot.requests.prefix(limit))) { request in
                            if let url = NeedsYouRequestLink(serverURL: snapshot.serverURL,
                                channelID: request.channelID, sequence: request.sequence).url {
                                HStack(alignment: .center, spacing: 8) {
                                    Link(destination: url) { requestRow(request) }
                                        .accessibilityLabel("\(request.channelName): \(request.quote)")
                                    if family != .systemSmall, let replyURL = NeedsYouRequestLink(
                                        serverURL: snapshot.serverURL, channelID: request.channelID,
                                        sequence: request.sequence).replyURL {
                                        Link(destination: replyURL) {
                                            Image(systemName: "arrowshape.turn.up.left")
                                                .font(.system(size: 13, weight: .medium))
                                                .frame(width: replyTargetSize, height: replyTargetSize)
                                                .contentShape(Rectangle())
                                        }
                                        .widgetAccentable()
                                        .accessibilityLabel("Reply in \(request.channelName)")
                                        .help("Reply in \(request.channelName)")
                                    }
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    footer(snapshot)
                }
            } else {
                status(title: "Open Toy Box to connect", symbol: "bubble.left.and.bubble.right")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .font(.system(size: 11))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .widgetURL(family == .systemSmall ? firstURL : NeedsYouSnapshot.mainURL)
    }

    private var firstURL: URL? {
        guard let snapshot, !snapshot.isStale(at: entry.date),
              let request = snapshot.requests.first else { return NeedsYouSnapshot.mainURL }
        return NeedsYouRequestLink(serverURL: snapshot.serverURL,
                                  channelID: request.channelID, sequence: request.sequence).url
    }

    private func status(title: String, symbol: String, lastUpdate: Date? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let lastUpdate {
                Text("Last update \(lastUpdate, format: .dateTime.hour().minute())")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func requestRow(_ request: NeedsYouSnapshot.Request) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(request.channelName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(request.quote).font(.system(size: 12)).lineLimit(family == .systemSmall ? 2 : 1)
                .multilineTextAlignment(.leading)
            if let date = request.requestedAt {
                Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func footer(_ snapshot: NeedsYouSnapshot) -> some View {
        let displayedCount = min(limit, snapshot.requests.count)
        if snapshot.waitingCount > displayedCount {
            Text("\(snapshot.waitingCount - displayedCount) more waiting")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

package struct NeedsYouEmptyState: View {
    package init() {}

    package var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 16, weight: .regular)).accessibilityHidden(true)
            Text("You're all caught up").font(.system(size: 13, weight: .regular)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
