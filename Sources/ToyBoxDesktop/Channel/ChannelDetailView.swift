import ChannelClient
import ChannelKit
import SwiftUI

struct ChannelDetailView: View {
    let store: ChannelStore
    let placement: InspectorPlacement
    /// Narrow windows show Overview as a sheet. The person's choice to show the column is kept,
    /// so a window that narrows only sets the column aside.
    let isNarrow: Bool
    let windowHeight: CGFloat
    @Binding var isOverviewSheetPresented: Bool
    /// Asks the composer to take focus once it appears.
    var focusesComposer = false
    var onBack: () -> Void
    /// Selects a channel in this window, as the sidebar does.
    var onSelect: (String) -> Void
    var onComposerFocused: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ManagementPresenter.self) private var management
    @Environment(ImageViewer.self) private var viewer
    @Environment(\.openSettings) private var openSettings
    @SceneStorage("inspectorVisible") private var inspectorVisible = true
    @SceneStorage("messageView") private var messageView = "all"

    private var isColumnPresented: Bool { !isNarrow && interaction.isInspectorPresented }
    /// AppKit reports column changes through a binding that can predate the latest layout, so the
    /// binding reads the latest presentation rather than a captured one. Only a divider drag
    /// changes the person's choice. The placement turns AppKit's own collapses into a new
    /// revision, which presents the column again.
    @ViewState private var column = ColumnPresentation()
    /// Switching channels keeps this view, its toolbar and its inspector column, and only moves
    /// the connection and the per-channel content to the new store.
    @ViewState private var connection = ChannelConnection()
    @ViewState private var titleFit = ChannelTitleFit()
    private var wideInspector: Binding<Bool> {
        let column = column
        let placement = placement
        let interaction = interaction
        column.isPresented = isColumnPresented
        column.revision = placement.revision
        return Binding(get: { column.isPresented },
                       set: { value in
                           if let choice = placement.columnChanged(to: value, presented: column.isPresented) {
                               interaction.isInspectorPresented = choice
                           }
                       })
    }
    private var narrowInspector: Binding<Bool> {
        Binding(get: { isNarrow && isOverviewSheetPresented && store.isLoaded && store.phase != .deleted },
                set: { isOverviewSheetPresented = $0 })
    }

    /// The image the viewer shows over this channel, which takes over the toolbar until it closes.
    private var viewing: ImageViewer.Presentation? { viewer.presentation }

    var body: some View {
        conversation
            .onGeometryChange(for: ChannelTitleFit.Span.self) { geometry in
                let frame = geometry.frame(in: .global)
                return ChannelTitleFit.Span(minX: frame.minX, maxX: frame.maxX)
            } action: { titleFit.update(detail: $0) }
            .settledLayout()
            .modifier(DetailMinimumWidth())
            .background(Color(nsColor: .textBackgroundColor))
            .inspector(isPresented: wideInspector) {
                OverviewInspector(store: store)
                    .settledLayout()
                    .inspectorColumnWidth(min: 280, ideal: 312, max: 400)
            }
            // The detail column and its inspector reach the window's trailing edge.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: {
                titleFit.update(windowWidth: $0)
            }
            // The toolbar draws its own backdrop over any container that keeps it in its top safe
            // area, so the canvas reaches under the glass toolbar only when its mount ignores it.
            // The open viewer is modal, which takes the conversation and Overview out of the
            // accessibility tree.
            .overlay { ImageViewerCanvas().ignoresSafeArea(edges: .top) }
            .sheet(isPresented: narrowInspector) {
                overviewSheet.frame(minWidth: 360, idealWidth: 360, maxWidth: 360, minHeight: 420,
                                    idealHeight: min(640, windowHeight - 100), maxHeight: max(420, windowHeight - 100))
            }
            // The viewer shows the sender and position as the system title and subtitle, as
            // Photos does. Otherwise the title menu stands in for the title.
            .navigationTitle(viewing?.sender ?? title)
            .navigationSubtitle(viewing?.subtitle ?? "")
            .toolbar(removing: viewing == nil ? .title : nil)
            .toolbar { toolbar }
            .onChange(of: title, initial: true) { titleFit.update(title: title) }
            .task {
                interaction.isInspectorPresented = model.launchOptions.isSnapshot
                    ? model.launchOptions.width >= 1000 : inspectorVisible
                interaction.messageView = model.launchOptions.isSnapshot ? .all : TranscriptView(rawValue: messageView) ?? .all
            }
            .task(id: ObjectIdentifier(store)) { connection.hold(store, in: model) }
            .onDisappear { connection.drop(in: model) }
            .onChange(of: interaction.isInspectorPresented) { _, value in
                if !model.launchOptions.isSnapshot { inspectorVisible = value }
            }
            .onChange(of: isColumnPresented) { placement.presentationChanged() }
            .onChange(of: interaction.messageView) { _, value in
                if !model.launchOptions.isSnapshot { messageView = value.rawValue }
            }
            // The transcript's scroll view takes over the composer once the channel loads, and the
            // replacement may not be in the window yet, so the request repeats until focus lands.
            .task(id: ComposerFocus(channel: ObjectIdentifier(store), isRequested: focusesComposer && store.isLoaded)) {
                guard focusesComposer, store.isLoaded else { return }
                for _ in 0..<20 {
                    interaction.focusComposer()
                    try? await Task.sleep(for: .milliseconds(50))
                    if Task.isCancelled { return }
                    if placement.window?.firstResponder is ComposerTextView { break }
                }
                onComposerFocused()
            }
            // Only a channel deleted while it's open sets Overview aside, not a switch to one.
            .onChange(of: ChannelDeletion(channel: ObjectIdentifier(store), isDeleted: store.phase == .deleted)) { old, new in
                if new.isDeleted, old.channel == new.channel {
                    interaction.isInspectorPresented = false
                    isOverviewSheetPresented = false
                }
            }
            .onChange(of: isNarrow) { _, narrow in
                // A sheet that's open when the window widens becomes the column.
                if !narrow && isOverviewSheetPresented {
                    isOverviewSheetPresented = false
                    interaction.isInspectorPresented = true
                }
            }
    }

    @ViewBuilder private var conversation: some View {
        if store.phase == .deleted {
            ContentUnavailableView {
                Label("This channel was deleted", systemImage: "bubble.left.and.exclamationmark.bubble.right")
            } description: {
                Text("Your local draft is kept on this Mac.")
            } actions: {
                Button("Back to Channels", action: onBack)
                if interaction.hasDraft {
                    Button("Copy Draft") { interaction.copyDraft?() }
                }
            }
        } else if !store.isLoaded, case .stale(let error, _) = store.phase {
            ContentUnavailableView {
                Label("Can't connect to Toy Box", systemImage: "wifi.exclamationmark")
            } description: {
                Text("\(model.serverURL)\n\(error)")
            } actions: {
                Button("Retry") { store.reconnect() }
                Button("Settings") { openSettings() }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) { ComposerArea(store: store) }
        } else {
            // The transcript's scroll position, paging and read state belong to one channel. Its bars
            // sit outside that identity, since a bar is rebuilt with the view it's attached to, so
            // the composer keeps its text view across a switch.
            ZStack {
                ConversationTranscript(store: store)
                    .id(ObjectIdentifier(store))
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                if case .stale(let error, _) = store.phase {
                    staleBanner(error)
                }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) { ComposerArea(store: store) }
        }
    }

    private func staleBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.secondary)
            Text("Reconnecting. Messages may be out of date").lineLimit(1)
            Button("Retry") { store.reconnect() }.buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .glassEffect(.regular, in: .capsule)
        .help(error)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .modifier(ConversationRail())
    }

    /// Narrow windows show Overview as a sheet, which keeps a visible title and a default Done.
    private var overviewSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Overview").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { isOverviewSheetPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            OverviewInspector(store: store)
        }
        .onExitCommand { isOverviewSheetPresented = false }
    }

    private var title: String { store.details?.name ?? catalogChannel?.name ?? "Channel" }

    /// The title menu keeps every channel one click away with the sidebar collapsed, in sidebar
    /// order and with the sidebar's attention as system menu-item badges.
    @ViewBuilder private var titleMenu: some View {
        Picker("Channel", selection: Binding(get: { store.id }, set: { if $0 != store.id { onSelect($0) } })) {
            ForEach(model.catalog?.channels ?? []) { channel in
                Text(model.sidebarChannel(channel).name)
                    .badge(Self.badge(model.sidebarAttention(channel)))
                    .tag(channel.id)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Button("New Channel…") { management.present(.newChannel) }
        Button("Edit Channel…") { management.present(.editChannel(channelId: store.id)) }
            .disabled(!store.phase.isLive)
    }

    static func badge(_ attention: ChannelAttention?) -> Text? {
        switch attention {
        case .waiting: Text("Input Needed")
        case .unread: Text("Unread")
        case .finished: Text("Done")
        case nil: nil
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if viewing != nil { viewerToolbar } else { conversationToolbar }
    }

    @ToolbarContentBuilder private var viewerToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward") { viewer.close() }
                .help("Back to Conversation")
                .keyboardShortcut(.cancelAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let url = viewer.shareURL {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .help("Share")
            } else {
                Button("Share", systemImage: "square.and.arrow.up") {}
                    .help("Share")
                    .disabled(true)
            }
            Menu {
                Button("Copy Image", systemImage: "doc.on.doc") { viewer.copyImage() }
                    .disabled(!viewer.canCopy)
                Button("Open in Preview", systemImage: "arrow.up.forward.app") { viewer.openInPreview() }
                    .disabled(viewer.shareURL == nil)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("More")
        }
    }

    @ToolbarContentBuilder private var conversationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ChannelTitleMenu(title: title, showsChevron: model.snapshot?.requestedState == "title-hover",
                             fit: titleFit) {
                titleMenu
            }
        }
        .sharedBackgroundVisibility(.hidden)
        .visibilityPriority(.high)
        ToolbarSpacer(.flexible)
        // The title truncates first, so every control fits down to the narrowest window. Should the
        // toolbar still run out of room, Channel Actions overflows before Message View, and the
        // title and Overview stay. Adjacent items share one glass capsule.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Message View", selection: Bindable(interaction).messageView) {
                    Text("All Messages").tag(TranscriptView.all)
                    Text("Your Messages").tag(TranscriptView.yours)
                }
            } label: {
                Label("Message View", systemImage: interaction.messageView == .all
                      ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(interaction.messageView == .all ? Color.secondary : Color.accentColor)
            }
            .menuIndicator(.hidden)
            .help(interaction.messageView == .all ? "Message View: All Messages" : "Message View: Your Messages")
            .accessibilityLabel("Message View")
            .accessibilityValue(interaction.messageView == .all ? "All Messages" : "Your Messages")
            .disabled(!store.isLoaded)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Open in Toy Box", systemImage: "arrow.up.forward.app") { model.openInToyBox(channelID: store.id) }
                Button("Edit Channel…", systemImage: "pencil") { management.present(.editChannel(channelId: store.id)) }
                    .disabled(!store.phase.isLive)
                Button("Refresh", systemImage: "arrow.clockwise") { store.reconnect() }
                Divider()
                Button("Delete Channel…", systemImage: "trash", role: .destructive) {
                    management.present(.deleteChannel(channelId: store.id))
                }
                .disabled(!store.phase.isLive)
            } label: {
                Label("Channel Actions", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Channel Actions")
            .help("Channel Actions")
        }
        .visibilityPriority(.low)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("Overview", systemImage: "sidebar.trailing") {
                if isNarrow { isOverviewSheetPresented.toggle() } else { interaction.isInspectorPresented.toggle() }
            }
                .help("Show or Hide Overview (Option-Command-0)")
                .disabled(store.phase == .deleted)
        }
        .visibilityPriority(.high)
    }

    private var catalogChannel: Channel? { model.catalog?.channels.first { $0.id == store.id } }
}

/// The one lane the transcript, the floating activity row and the composer share: the whole
/// detail column inside 24-point insets, with no maximum. Messages keep their own readable caps
/// within it, so a wider window adds air between the two sides rather than longer lines.
struct ConversationRail: ViewModifier {
    static let inset: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.inset)
    }
}

private final class ColumnPresentation {
    var isPresented = false
    var revision = 0
}

/// The one channel a detail keeps connected, which moves with the selection.
@MainActor private final class ChannelConnection {
    private var store: ChannelStore?

    func hold(_ store: ChannelStore, in model: AppModel) {
        guard store !== self.store else { return }
        model.acquire(store)
        if let held = self.store { model.release(held) }
        self.store = store
    }

    func drop(in model: AppModel) {
        if let store { model.release(store) }
        store = nil
    }
}

private struct ComposerFocus: Equatable {
    let channel: ObjectIdentifier
    let isRequested: Bool
}

private struct ChannelDeletion: Equatable {
    let channel: ObjectIdentifier
    let isDeleted: Bool
}
