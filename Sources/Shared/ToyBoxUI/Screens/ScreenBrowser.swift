import ChannelClient
import ChannelKit
import SwiftUI

/// Picks a display or window to watch, by how each looks right now. Each appearance or refresh
/// fetches the list once, with one thumbnail per screen, and nothing polls.
public struct ScreenBrowser: View {
    private let api: ChannelAPI
    private let open: (Screen) -> Void
    @ViewState private var screens: Result<ScreenList, any Error>?
    /// Counts finished loads, so a refresh fetches every thumbnail again even for the same screens.
    @ViewState private var generation = 0
    @ViewState private var isLoading = false
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
        // The search field floats above the keyboard and covers the last results until it goes away.
        .scrollDismissesKeyboard(.immediately)
        .task { await load() }
        .refreshable { await load() }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    .help("Refresh (Command-R)")
                    .keyboardShortcut("r")
                    .disabled(isLoading)
            }
        }
        #endif
    }

    private func load() async {
        isLoading = true
        do { screens = .success(try await api.screens()) } catch { screens = .failure(error) }
        generation += 1
        isLoading = false
    }

    private func section(_ title: String, _ screens: [Screen], minimumWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text(screens.count, format: .number).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: 12, alignment: .top)],
                      spacing: 16) {
                ForEach(screens) { Card(api: api, screen: $0, generation: generation, open: open) }
            }
        }
    }

    /// A screen as it looked at the browser's last load, over a placeholder until its first thumbnail
    /// loads. A refresh keeps the old thumbnail until the new one is decoded.
    private struct Card: View {
        let api: ChannelAPI
        let screen: Screen
        let generation: Int
        let open: (Screen) -> Void
        @Environment(\.displayScale) private var displayScale
        /// Rounded up to 64-point steps, so resizing the window decodes again only at each step.
        @ViewState private var width = 0.0
        /// Kept with the load that fetched it, so a resize only decodes again.
        @ViewState private var jpeg: (generation: Int, data: Data)?
        @ViewState private var thumbnail: CGImage?

        private struct Request: Equatable {
            let pixels: Int
            let generation: Int
        }

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
            .task(id: Request(pixels: Int(width * displayScale), generation: generation)) {
                let pixels = Int(width * displayScale)
                guard pixels > 0 else { return }
                if jpeg?.generation != generation {
                    guard let data = try? await api.screenThumbnail(id: screen.id), !Task.isCancelled else { return }
                    jpeg = (generation, data)
                }
                guard let data = jpeg?.data else { return }
                let image = await Task.detached(priority: .userInitiated) {
                    ChannelImageDecoder.thumbnail(data: data, maxPixelSize: pixels)
                }.value
                // A decode for an earlier width or load can finish after this one.
                if !Task.isCancelled { thumbnail = image }
            }
        }
    }
}
