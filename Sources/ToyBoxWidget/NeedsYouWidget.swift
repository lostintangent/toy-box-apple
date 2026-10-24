import AppKit
import ChannelKit
import OSLog
import SwiftUI
import WidgetKit

struct NeedsYouEntry: TimelineEntry {
    var date: Date
    var snapshot: NeedsYouSnapshot?
}

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

    private var limit: Int { family == .systemSmall ? 1 : family == .systemMedium ? 2 : 4 }
    private var snapshot: NeedsYouSnapshot? { entry.snapshot.flatMap { $0.isAvailable ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 8) {
            HStack {
                Link(destination: NeedsYouSnapshot.mainURL) {
                    Text("Needs you").font(.system(size: 13, weight: .semibold))
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
                    ForEach(Array(snapshot.requests.prefix(limit))) { request in
                        if let url = NeedsYouRequestLink(serverURL: snapshot.serverURL,
                            channelID: request.channelID, sequence: request.sequence).url {
                            Link(destination: url) { requestRow(request) }
                                .accessibilityLabel("\(request.channelName): \(request.quote)")
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
            if let data = request.avatarPNG, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().widgetAccentedRenderingMode(.fullColor)
                    .frame(width: 24, height: 24).accessibilityHidden(true)
            } else {
                Image(systemName: "questionmark.bubble")
                    .frame(width: 24, height: 24).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(request.channelName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(request.quote).font(.system(size: 12)).lineLimit(family == .systemMedium ? 1 : 2)
                HStack(spacing: 3) {
                    if let name = request.agentName { Text(name).lineLimit(1) }
                    if let date = request.requestedAt {
                        if request.agentName != nil { Text("·") }
                        Text("\(date, style: .relative) ago").lineLimit(1).layoutPriority(1)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(_ snapshot: NeedsYouSnapshot) -> some View {
        HStack {
            if snapshot.waitingCount > limit {
                Text("+\(snapshot.waitingCount - limit) more")
            }
            Spacer(minLength: 2)
            if snapshot.isStale(at: entry.date) {
                Text("May be out of date")
            } else {
                Text("Updated \(snapshot.updatedAt, style: .relative)")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
    }
}
