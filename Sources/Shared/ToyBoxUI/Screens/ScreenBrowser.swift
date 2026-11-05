import ChannelClient
import ChannelKit
import SwiftUI

/// Picks a display or window to watch, by how each looks right now. Each appearance fetches the
/// list once, with one thumbnail per screen, and nothing polls.
public struct ScreenBrowser: View {
    private let api: ChannelAPI
    private let open: (Screen) -> Void
    @ViewState private var screens: Result<ScreenList, any Error>?
    @ViewState private var query = ""

    public init(api: ChannelAPI, open: @escaping (Screen) -> Void) {
        self.api = api
        self.open = open
    }

    public var body: some View {
        ScrollView {
            switch screens {
            case nil:
                DelayedProgressView().padding(.top, 80)
            case .failure(let error):
                ContentUnavailableView {
                    Label("Couldn't Load Screens", systemImage: "display.trianglebadge.exclamationmark")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            case .success(let list):
                let term = query.trimmingCharacters(in: .whitespaces)
                let windows = list.windows.filter { $0.matches(term) }
                VStack(alignment: .leading, spacing: 20) {
                    section("Displays", list.displays, minimumWidth: 260)
                    section("Windows", windows, minimumWidth: 150)
                    if windows.isEmpty {
                        Text("No windows found").italic().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
                .padding()
            }
        }
        .searchable(text: $query, prompt: "Search windows")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { screens = .success(try await api.screens()) } catch { screens = .failure(error) }
    }

    private func section(_ title: String, _ screens: [Screen], minimumWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text(screens.count, format: .number).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: 12, alignment: .top)],
                      spacing: 16) {
                ForEach(screens) { Card(api: api, screen: $0, open: open) }
            }
        }
    }

    /// A screen as it looked when the browser opened, over a placeholder until its thumbnail loads.
    private struct Card: View {
        let api: ChannelAPI
        let screen: Screen
        let open: (Screen) -> Void
        @Environment(\.displayScale) private var displayScale
        /// Rounded up to 64-point steps, so resizing the window decodes again only at each step.
        @ViewState private var width = 0.0
        @ViewState private var jpeg: Data?
        @ViewState private var thumbnail: CGImage?

        var body: some View {
            Button { open(screen) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .overlay {
                            if let thumbnail {
                                Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                            }
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(screen.title).font(.callout.weight(.medium))
                        if let application = screen.application {
                            Text(application).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onGeometryChange(for: Double.self) { ($0.size.width / 64).rounded(.up) * 64 } action: { width = $0 }
            // A fitted thumbnail is never wider than its card, so it decodes at the card's pixels.
            .task(id: width * displayScale) {
                let pixels = Int(width * displayScale)
                guard pixels > 0 else { return }
                if jpeg == nil { jpeg = try? await api.screenThumbnail(id: screen.id) }
                guard let jpeg else { return }
                let image = await Task.detached(priority: .userInitiated) {
                    ChannelImageDecoder.thumbnail(data: jpeg, maxPixelSize: pixels)
                }.value
                // A decode for an earlier width can finish after this one.
                if !Task.isCancelled { thumbnail = image }
            }
        }
    }
}
