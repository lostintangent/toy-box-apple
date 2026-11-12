import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ChannelDetailView: View {
    let store: ChannelStore
    let placement: InspectorPlacement
    let titleFit: ChannelTitleFit
    /// Narrow windows show Overview as a sheet. The person's choice to show the column is kept,
    /// so a window that narrows only sets the column aside.
    let isNarrow: Bool
    let windowHeight: CGFloat
    @Binding var isOverviewSheetPresented: Bool
    /// A window draws its channel's first content before Overview and the composer build, which
    /// keeps their first build off the launch's critical path. Once mounted, they stay.
    @Binding var mountsSurroundings: Bool
    var onBack: () -> Void
    /// Selects a channel in this window, as the sidebar does.
    var onSelect: (ChannelTarget) -> Void
    @Environment(AppModel.self) private var model
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ManagementPresenter.self) private var management
    @Environment(ImageViewer.self) private var viewer
    @Environment(ArtifactOpener.self) private var artifacts
    @Environment(\.openSettings) private var openSettings
    @SceneStorage("inspectorVisible") private var inspectorVisible = true
    @SceneStorage("messageView") private var messageView = "all"

    /// Switching channels keeps this view and its toolbar, and only moves the connection and the
    /// per-channel content to the new store.
    @ViewState private var connection = ChannelConnection()
    /// Truncates the open image's title before NSToolbar overflows Copy and Share.
    @ViewState private var imageTitleFit = ViewerTitleFit()
    private var showsSurroundings: Bool { mountsSurroundings || model.launchOptions.isSnapshot }
    /// The transcript, an error or the deleted state is on screen.
    private var hasFirstContent: Bool {
        switch store.phase {
        case .failed, .deleted: true
        case .connecting, .connected: store.isLoaded
        }
    }
    private var narrowInspector: Binding<Bool> {
        Binding(get: { isNarrow && isOverviewSheetPresented && store.isLoaded && store.phase != .deleted },
                set: { isOverviewSheetPresented = $0 })
    }

    /// The image the viewer shows over this channel, which takes over the toolbar until it closes.
    private var viewing: ImageViewer.Presentation? { viewer.presentation }

    var body: some View {
        conversation
            // An open artifact hides the conversation without removing it, so its scroll position,
            // draft and paging survive. It's out of sight, VoiceOver, the pointer and the key view
            // loop, and Find stays with the viewer.
            .opacity(artifacts.isPresented ? 0 : 1)
            .accessibilityHidden(artifacts.isPresented)
            .allowsHitTesting(!artifacts.isPresented)
            .disabled(artifacts.isPresented)
            .onGeometryChange(for: ChannelTitleFit.Span.self) { geometry in
                let frame = geometry.frame(in: .global)
                return ChannelTitleFit.Span(minX: frame.minX, maxX: frame.maxX)
            } action: {
                titleFit.update(detail: $0)
                imageTitleFit.update(detail: $0)
            }
            .settledLayout()
            .modifier(DetailMinimumWidth())
            .background(Color(nsColor: .textBackgroundColor))
            // The image gallery manages its own toolbar clearance. Artifact pages inherit the
            // toolbar safe area so their scroll containers receive its inset. Overview stays
            // beside either viewer.
            .overlay { ImageViewerCanvas() }
            .overlay { ArtifactViewerCanvas(store: store) }
            .sheet(isPresented: narrowInspector) {
                overviewSheet.frame(minWidth: 360, idealWidth: 360, maxWidth: 360, minHeight: 420,
                                    idealHeight: min(640, windowHeight - 100), maxHeight: max(420, windowHeight - 100))
            }
            // Each viewer's title menu, or the channel's, stands in for the system title. The
            // window keeps whichever title is showing for the Window menu.
            .navigationTitle(artifacts.artifact?.title ?? viewing?.sender ?? title)
            .navigationSubtitle(artifacts.isPresented ? artifacts.subtitle : viewing?.subtitle ?? "")
            .toolbar(removing: .title)
            .toolbar { toolbar }
            .onChange(of: title, initial: true) { titleFit.update(title: title) }
            .onChange(of: viewing, initial: true) { _, viewing in
                guard let viewing else { return }
                imageTitleFit.window = placement.window
                imageTitleFit.update(title: viewing.sender, subtitle: viewing.subtitle)
            }
            .task {
                interaction.isInspectorPresented = model.launchOptions.isSnapshot
                    ? model.launchOptions.width >= 1000 : inspectorVisible
                interaction.messageView = model.launchOptions.isSnapshot ? .all : TranscriptFilter(rawValue: messageView) ?? .all
            }
            // Overview and the composer mount once the first content has drawn, or after a second
            // for a channel that's slow to connect.
            .task(id: hasFirstContent) {
                guard !mountsSurroundings else { return }
                if hasFirstContent {
                    await passEnd()
                } else {
                    try? await Task.sleep(for: .seconds(1))
                }
                if !Task.isCancelled {
                    mountsSurroundings = true
                }
            }
            .task(id: ObjectIdentifier(store)) { connection.hold(store, in: model) }
            .onDisappear { connection.drop(in: model) }
            .onChange(of: interaction.isInspectorPresented) { _, value in
                if !model.launchOptions.isSnapshot { inspectorVisible = value }
            }
            .onChange(of: interaction.messageView) { _, value in
                if !model.launchOptions.isSnapshot { messageView = value.rawValue }
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
            .onChange(of: artifacts.isPresented) { _, presented in
                if presented { isOverviewSheetPresented = false }
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
        } else if !store.isLoaded, case .failed(let error) = store.phase {
            ContentUnavailableView {
                Label("Can't connect to Toy Box", systemImage: "wifi.exclamationmark")
            } description: {
                Text("\(store.api.baseURL.absoluteString)\n\(error)")
            } actions: {
                Button("Retry") { store.reconnect() }
                Button("Settings") { model.settingsTab = .servers; openSettings() }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) { composer }
        } else {
            // The transcript's scroll position, paging and read state belong to one channel. Its bars
            // sit outside that identity, since a bar is rebuilt with the view it's attached to, so
            // the composer keeps its text view across a switch.
            ZStack {
                ConversationTranscript(store: store)
                    .id(ObjectIdentifier(store))
            }
            .overlay(alignment: .top) {
                ReconnectingNotice(failure: store.phase.message, isBelowFind: interaction.isFinding)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) { composer }
        }
    }

    /// Until the composer mounts, a bar of its resting height keeps the transcript's bottom inset.
    @ViewBuilder private var composer: some View {
        if showsSurroundings {
            ComposerArea(store: store)
        } else {
            Color.clear.frame(height: 125)
        }
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
    /// order and with the sidebar's attention as system menu-item badges. Several servers each get
    /// a section, as in the sidebar.
    @ViewBuilder private var titleMenu: some View {
        let selected = store.target
        Picker("Channel", selection: Binding(get: { selected }, set: { if let target = $0, target != selected { onSelect(target) } })) {
            if model.catalogs.count > 1 {
                ForEach(model.catalogs, id: \.api.baseURL) { catalog in
                    Section(catalog.name) { channelItems(in: catalog) }
                }
            } else if let catalog {
                channelItems(in: catalog)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Button("New Channel…", systemImage: "plus") {
            management.present(.newChannel(server: store.api.baseURL.absoluteString))
        }
        Divider()
        Button("Edit Channel…", systemImage: "pencil") {
            if let selected { management.present(.editChannel(selected)) }
        }
        .disabled(!store.phase.isConnected)
        Button("Open in Toy Box", systemImage: "arrow.up.forward.app") {
            if let selected { model.openInToyBox(selected) }
        }
        Divider()
        Button("Delete Channel…", systemImage: "trash", role: .destructive) {
            if let target = store.target { management.present(.deleteChannel(target)) }
        }
        .disabled(!store.phase.isConnected)
    }

    private func channelItems(in catalog: ChannelCatalogStore) -> some View {
        let presentation = model.sidebarPresentation(for: catalog)
        return ForEach(catalog.channels) { channel in
            Text(presentation.channel(channel).name)
                .badge(Self.badge(presentation.attention(channel)))
                .tag(catalog.target(channel.id))
        }
    }

    static func badge(_ attention: Channel.Attention?) -> Text? {
        switch attention {
        case .waiting: Text("Input Needed")
        case .unread: Text("Unread")
        case .finished: Text("Done")
        case nil: nil
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if artifacts.isPresented {
            ArtifactViewerToolbar(opener: artifacts, store: store, app: model, interaction: interaction)
        } else if viewing != nil {
            viewerToolbar
        } else {
            conversationToolbar
        }
    }

    /// Like the artifact viewer's: Back, then the title as a menu of every image action, with Copy
    /// and Share also as buttons.
    @ToolbarContentBuilder private var viewerToolbar: some ToolbarContent {
        ViewerLeadingToolbar(title: viewing?.sender ?? "", subtitle: viewing?.subtitle ?? "",
                             help: viewing.map { "\($0.sender)\n\($0.filename)" } ?? "",
                             fit: imageTitleFit, back: { viewer.close() }) {
            Button("Copy Image", systemImage: "doc.on.doc") { viewer.copyImage() }
                .disabled(!viewer.canCopy)
            Button("Open in Preview", systemImage: "arrow.up.forward.app") { viewer.openInPreview() }
                .disabled(viewer.shareURL == nil)
        }
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Copy", systemImage: "doc.on.doc") { viewer.copyImage() }
                .help("Copy Image")
                .disabled(!viewer.canCopy)
            if let url = viewer.shareURL {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .help("Share")
            } else {
                Button("Share", systemImage: "square.and.arrow.up") {}
                    .help("Share")
                    .disabled(true)
            }
        }
    }

    @ToolbarContentBuilder private var conversationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ChannelTitleMenu(store: store, title: title, fit: titleFit) {
                titleMenu
            }
        }
        .visibilityPriority(.high)
        ToolbarSpacer(.flexible)
        // The title truncates first, so every control fits down to the narrowest window. Should the
        // toolbar still run out of room, Message View overflows, and the title and Overview stay.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Message View", selection: Bindable(interaction).messageView) {
                    Label("All Messages", systemImage: "bubble.left.and.bubble.right").tag(TranscriptFilter.all)
                    Label("Your Messages", systemImage: "person").tag(TranscriptFilter.yours)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Message View", systemImage: "line.3.horizontal.decrease")
                    .foregroundStyle(interaction.messageView == .all ? Color.secondary : Color.accentColor)
            }
            .menuIndicator(.hidden)
            .help(interaction.messageView == .all ? "Message View: All Messages" : "Message View: Your Messages")
            .accessibilityLabel("Message View")
            .accessibilityValue(interaction.messageView == .all ? "All Messages" : "Your Messages")
            .disabled(!store.isLoaded)
        }
        .visibilityPriority(.low)
    }

    /// The catalog of this channel's server.
    private var catalog: ChannelCatalogStore? { model.catalogs.first(at: store.api.baseURL.absoluteString) }
    private var catalogChannel: Channel? { catalog?.channels.first { $0.id == store.id } }
}

/// Floats over a cached transcript whose stream dropped, like the phone's, so the rows, their
/// scroll inset and the reader's anchor never move when it comes or goes. The channel retries on
/// its own, so it offers no Retry.
struct ReconnectingNotice: View {
    /// Find's bar spans the top of the transcript: a 28-point field inside 6 points above and below.
    static let findBarHeight: CGFloat = 40

    let failure: String?
    let isBelowFind: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let failure {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Reconnecting to server").font(.subheadline.weight(.semibold))
                        Text("Messages may be out of date").font(.caption).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                .help(failure)
                .accessibilityElement(children: .combine)
                .accessibilityHint(failure)
                .padding(.top, isBelowFind ? Self.findBarHeight + 8 : 8)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
            }
        }
        .frame(maxWidth: .infinity)
        .modifier(ConversationRail())
        .animation(.easeOut(duration: 0.2), value: failure != nil)
    }
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

/// The one channel a detail keeps connected, which moves with the selection.
@MainActor private final class ChannelConnection {
    private var store: ChannelStore?

    func hold(_ store: ChannelStore, in model: AppModel) {
        guard store !== self.store else { return }
        model.hold(store)
        if let held = self.store { model.release(held) }
        self.store = store
    }

    func drop(in model: AppModel) {
        if let store { model.release(store) }
        store = nil
    }
}

/// Waits until the main run loop has no more work and is about to sleep, once Core Animation has
/// committed what that work drew.
@MainActor private func passEnd() async {
    await withCheckedContinuation { continuation in
        // Core Animation commits at order 2,000,000, so the highest order runs after it.
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, false, .max
        ) { _, _ in continuation.resume() }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        // An observer added while the run loop calls observers first runs on the next pass.
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

private struct ChannelDeletion: Equatable {
    let channel: ObjectIdentifier
    let isDeleted: Bool
}
