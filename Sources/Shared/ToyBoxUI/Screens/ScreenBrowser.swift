import ChannelClient
import ChannelKit
import SwiftUI

/// Refetches a screen list and every thumbnail, from its title menu or the Mac's Command-R. It's
/// disabled while a load is in flight.
public struct ScreenRefresh {
    public let isLoading: Bool
    let load: @MainActor () -> Void

    @MainActor public func callAsFunction() { load() }
}

/// Picks a display or window to watch, by how each looks right now. Each appearance or refresh
/// fetches the list once, with one thumbnail per screen, and nothing polls. The app's toolbar
/// holds Refresh, in its title menu.
public struct ScreenBrowser<Toolbar: ToolbarContent>: View {
    private let api: ChannelAPI
    private let open: (Screen) -> Void
    private let toolbar: (ScreenRefresh) -> Toolbar
    @ViewState private var screens: Result<ScreenList, any Error>?
    /// Counts finished loads, so a refresh fetches every thumbnail again even for the same screens.
    @ViewState private var generation = 0
    @ViewState private var isLoading = false
    @ViewState private var query = ""
    #if os(macOS)
    /// Whether the list shows, rather than a screen pushed over it, so Command-R refreshes only the list.
    @ViewState private var isShown = false
    #endif

    public init(api: ChannelAPI, open: @escaping (Screen) -> Void,
                @ToolbarContentBuilder toolbar: @escaping (ScreenRefresh) -> Toolbar) {
        self.api = api
        self.open = open
        self.toolbar = toolbar
    }

    private var refresh: ScreenRefresh {
        ScreenRefresh(isLoading: isLoading) { Task { await load() } }
    }

    public var body: some View {
        Group {
            // Not in the scroll view, which would hug it to the top and only be as wide as it is.
            if case .failure = screens {
                ContentUnavailableView {
                    Label("Unable to List Screens", systemImage: "display.trianglebadge.exclamationmark")
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ScrollView {
                    if case .success(let list) = screens {
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
                    } else {
                        DelayedProgressView().padding(.top, 80)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search windows")
        // The search field floats above the keyboard and covers the last results until it goes away.
        .scrollDismissesKeyboard(.immediately)
        .task { await load() }
        .refreshable { await load() }
        .toolbar { toolbar(refresh) }
        #if os(macOS)
        .onAppear { isShown = true }
        .onDisappear { isShown = false }
        .focusedSceneValue(\.screenRefresh, isShown ? refresh : nil)
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

#if os(macOS)
private struct ScreenRefreshKey: FocusedValueKey {
    typealias Value = ScreenRefresh
}

extension FocusedValues {
    /// The focused Screens window's Refresh, while it shows its list.
    public var screenRefresh: ScreenRefresh? {
        get { self[ScreenRefreshKey.self] }
        set { self[ScreenRefreshKey.self] = newValue }
    }
}
#endif
