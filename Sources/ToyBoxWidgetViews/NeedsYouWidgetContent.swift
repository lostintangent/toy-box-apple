import ChannelKit
import SwiftUI
import WidgetKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    let family: WidgetFamily
    let replyTargetSize: CGFloat
    let maximumRequests: Int?
    @Environment(\.widgetRenderingMode) private var renderingMode

    package init(entry: NeedsYouEntry, family: WidgetFamily,
                 replyTargetSize: CGFloat = 28, maximumRequests: Int? = nil) {
        self.entry = entry
        self.family = family
        self.replyTargetSize = replyTargetSize
        self.maximumRequests = maximumRequests
    }

    private var limit: Int {
        min(maximumRequests ?? 5, family == .systemSmall ? 1 : family == .systemMedium ? 2 : 5)
    }
    private var snapshot: NeedsYouSnapshot? { entry.snapshot.flatMap { $0.isAvailable ? $0 : nil } }

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Link(destination: NeedsYouSnapshot.mainURL) {
                    Text("Needs you").font(.system(size: 13, weight: .semibold)).widgetAccentable()
                }
                Spacer()
                if let snapshot {
                    Text(snapshot.waitingCount, format: .number)
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let snapshot {
                if snapshot.waitingCount == 0 {
                    Spacer(minLength: 0)
                    emptyState
                    Spacer(minLength: 0)
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
                                        .accessibilityLabel("Reply to \(request.agentName ?? "request") in \(request.channelName)")
                                        .help("Reply to \(request.agentName ?? "request") in \(request.channelName)")
                                    }
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                footer(snapshot)
            } else {
                Spacer(minLength: 0)
                Image(systemName: "bubble.left.and.bubble.right").font(.title2).foregroundStyle(.secondary)
                Text("Open Toy Box to connect").font(.headline)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .widgetURL(family == .systemSmall ? firstURL : NeedsYouSnapshot.mainURL)
    }

    private var firstURL: URL? {
        guard let snapshot, let request = snapshot.requests.first else { return NeedsYouSnapshot.mainURL }
        return NeedsYouRequestLink(serverURL: snapshot.serverURL,
                                  channelID: request.channelID, sequence: request.sequence).url
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "checkmark.bubble").font(.title2).foregroundStyle(.secondary)
            Text("Nothing needs you").font(.headline)
            if family != .systemSmall {
                Text("Your teams will appear here when they need a reply.").foregroundStyle(.secondary)
            }
        }
    }

    private func requestRow(_ request: NeedsYouSnapshot.Request) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let image = avatar(request.avatarPNG) {
                image.resizable()
                    .widgetAccentedRenderingMode(renderingMode == .fullColor ? .fullColor
                        : renderingMode == .accented ? .accentedDesaturated : .desaturated)
                    .frame(width: 24, height: 24).accessibilityHidden(true)
            } else {
                Image(systemName: "questionmark.bubble")
                    .frame(width: 24, height: 24).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(request.channelName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(request.quote).font(.system(size: 12)).lineLimit(family == .systemSmall ? 2 : 1)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 3) {
                    if let name = request.agentName { Text(name).lineLimit(1) }
                    if let date = request.requestedAt {
                        if request.agentName != nil { Text("·") }
                        Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow)).lineLimit(1)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func avatar(_ data: Data?) -> Image? {
        guard let data else { return nil }
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }

    private func footer(_ snapshot: NeedsYouSnapshot) -> some View {
        let isStale = snapshot.isStale(at: entry.date)
        let displayedCount = min(limit, snapshot.requests.count)
        return HStack {
            if snapshot.waitingCount > displayedCount && (family != .systemSmall || !isStale) {
                Text("+\(snapshot.waitingCount - displayedCount) more")
            }
            Spacer(minLength: 2)
            if isStale {
                Text("May be out of date")
            } else {
                #if os(iOS)
                Text("Updated \(snapshot.updatedAt, format: .dateTime.hour().minute())")
                #else
                if family != .systemSmall {
                    Text("Updated \(snapshot.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))")
                }
                #endif
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
    }
}
