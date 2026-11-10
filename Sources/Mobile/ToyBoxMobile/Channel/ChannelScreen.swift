import ChannelClient
import ChannelKit
import SwiftUI
import TipKit
import ToyBoxUI

struct ChannelScreen: View {
    let store: ChannelStore
    @Environment(AppModel.self) private var model
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ManagementPresenter.self) private var management
    @Environment(ChannelArtifactSession.self) private var artifacts
    @Environment(TranscriptGallery.self) private var gallery
    @Environment(Overview.self) private var overview
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.usesVerticalToolbar) private var usesVerticalToolbar
    @ViewState private var keyboardIsVisible = false
    @ViewState private var permissionTipIsAvailable = false
    @ViewState private var width: CGFloat = 0
    private let permissionTip = NotificationPermissionTip()

    private var reader: ChannelReaderVisibility {
        ChannelReaderVisibility(
            artifactRequested: artifacts.isPresented,
            imageRequested: gallery.session != nil,
            compactOverviewRequested: sizeClass == .compact && interaction.isInspectorPresented,
            compactOverviewPresented: overview.isCompactSheetPresented
        )
    }

    /// The conversation, or the artifact open over it once it has a page. An image over it, or an
    /// artifact that's gone, shows Siri nothing.
    private var screenEntity: ScreenEntity? {
        guard reader.isVisible else { return .channel(store.id) }
        guard artifacts.isPresented, !artifacts.isUnavailable, let artifact = artifacts.artifact else { return nil }
        return .artifact(channelID: store.id, artifactID: artifact.id)
    }

    private var showsPermissionTip: Bool {
        permissionTipIsAvailable && model.notifications.canOfferPermissionTip
            && model.visibleChannelID == store.id
            && !store.phase.isUnavailable && store.requestSequence != nil && !model.isCovered
            && management.flow == nil && !reader.requested && !overview.isCompactSheetPresented
            && !(sizeClass == .compact && interaction.isInspectorPresented)
            && !interaction.isRequestPreviewPresented && !keyboardIsVisible
            && !model.composerSession(for: store).editor.isFocused
    }

    /// With no vertical bar, a compact `.bottomBar` would sit under the composer, so Message View
    /// moves into the title menu's Channel Actions and a filtered transcript names itself under the
    /// title instead.
    private var messageViewIsInActions: Bool { sizeClass == .compact && !usesVerticalToolbar }

    /// The widest the title's text can be. The bar gives a leading item its whole ideal width and
    /// moves it to the overflow menu when that doesn't fit, so a long name truncates first. Besides
    /// the margins and the capsule's insets, the bar keeps room for its buttons, even when they stand
    /// in the vertical bar: Back and Overview, or the sidebar toggle, Message View and Overview.
    private var titleMaxWidth: CGFloat? {
        guard width > 0 else { return nil }
        let buttons: CGFloat = sizeClass == .compact ? 2 : 3
        return max(width - 80 - buttons * (44 + 8), 60)
    }

    var body: some View {
        ZStack {
            conversation
                .opacity(reader.isVisible ? 0 : 1)
                .allowsHitTesting(!reader.requested)
                .accessibilityHidden(reader.requested)
            if reader.isVisible {
                if artifacts.isPresented {
                    ArtifactViewer(session: artifacts)
                } else {
                    TranscriptGalleryView(gallery: gallery)
                }
            }
        }
            .softwareKeyboardVisibility($keyboardIsVisible)
            .safeAreaBar(edge: .top, spacing: 0) {
                if showsPermissionTip {
                    TipView(permissionTip) { _ in
                        permissionTip.invalidate(reason: .actionPerformed)
                        Task { await model.notifications.enable() }
                    }
                    .padding(.horizontal, sizeClass == .compact ? 16 : 20)
                    .padding(.vertical, 8)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // Names the screen for Back and VoiceOver, while the title button draws it. Readers keep
            // their own titles.
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: reader.requested ? nil : .title)
            .task(id: model.notifications.tipsAvailable) {
                guard model.notifications.tipsAvailable else { return }
                for await available in permissionTip.shouldDisplayUpdates {
                    permissionTipIsAvailable = available
                }
            }
            .onAppear { model.visibleChannelID = store.id }
            .onChange(of: store.id) { _, id in model.visibleChannelID = id }
            .onChange(of: screenEntity, initial: true) { _, entity in model.screenEntity = entity }
            .channelActivity(store.id, showing: screenEntity)
            .onChange(of: store.artifacts, initial: true) { _, current in
                artifacts.configure(api: store.api, channelID: store.id, artifacts: current)
            }
            .onChange(of: artifacts.isPresented, initial: true) { _, presented in
                if presented, artifacts.isPresented { gallery.close() }
            }
            .onChange(of: gallery.session?.id, initial: true) { _, id in
                if id != nil, gallery.session?.id == id { artifacts.close() }
            }
            .onChange(of: reader.requested, initial: true) { _, requested in
                interaction.isArtifactViewerPresented = requested
                if requested, sizeClass == .compact { interaction.isInspectorPresented = false }
            }
            .onChange(of: store.phase, initial: true) { _, phase in
                if phase == .deleted {
                    artifacts.close()
                    gallery.close()
                    interaction.isInspectorPresented = false
                }
            }
            .onDisappear {
                interaction.isArtifactViewerPresented = false
                if model.visibleChannelID == store.id { model.visibleChannelID = nil }
                if model.screenEntity?.channelID == store.id { model.screenEntity = nil }
            }
            .toolbar {
                if !reader.requested { conversationToolbar }
            }
    }

    private var title: String {
        store.details?.name ?? model.catalog?.channels.first { $0.id == store.id }?.name ?? ""
    }

    @ViewBuilder
    private var conversation: some View {
        Group {
            if store.phase == .deleted {
                DeletedChannelView(draft: model.composerSession(for: store).draft) {
                    model.selectedChannelID = nil
                }
            } else {
                ConversationView(store: store)
                    // Like the Mac's, rows pass softly under the floating title and bar buttons.
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .safeAreaBar(edge: .bottom, spacing: 0) {
                        if !interaction.isFinding {
                            ComposerSurface(session: model.composerSession(for: store))
                                .id(ObjectIdentifier(store))
                                .findSwapTransition()
                        }
                    }
            }
        }
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            ChannelTitleMenu(title: title,
                             subtitle: messageViewIsInActions && interaction.messageView == .yours ? "Your Messages" : nil,
                             maxWidth: titleMaxWidth) {
                channelActions
            }
        }
        if sizeClass == .compact {
            ToolbarItem(placement: .primaryAction) {
                overviewButton
            }
            if !messageViewIsInActions {
                ToolbarItem(placement: .bottomBar) {
                    messageView
                }
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                messageView
                overviewButton
            }
        }
    }

    /// A standalone Message View item uses the accent while Your Messages is on.
    @ViewBuilder
    private var messageView: some View {
        if interaction.messageView == .yours {
            messageViewMenu
                .tint(.accentColor)
                .accessibilityValue("Your Messages")
        } else {
            messageViewMenu
        }
    }

    private var messageViewMenu: some View {
        Menu("Message View", systemImage: "line.3.horizontal.decrease") {
            messageViewPicker
        }
    }

    private var messageViewPicker: some View {
        @Bindable var interaction = interaction
        return Picker("Message View", selection: $interaction.messageView) {
            Label("All Messages", systemImage: "bubble.left.and.bubble.right").tag(TranscriptFilter.all)
            Label("Your Messages", systemImage: "person").tag(TranscriptFilter.yours)
        }
        .disabled(store.phase == .deleted)
    }

    @ViewBuilder
    private var channelActions: some View {
        if messageViewIsInActions {
            Section("Message View") {
                messageViewPicker
            }
        }
        Button("Find in Conversation", systemImage: "magnifyingglass") {
            interaction.findInChannel()
        }
        .disabled(store.phase == .deleted)
        ChannelFollowMenuAction(store: store)
        Button("Open in Toy Box", systemImage: "arrow.up.forward.square") {
            model.openInToyBox(channelID: store.id)
        }
        .disabled(store.phase == .deleted || model.channelURL(channelID: store.id) == nil)
        Divider()
        Button("Edit Channel", systemImage: "pencil") {
            if let target = store.target { management.present(.editChannel(target)) }
        }
        .disabled(!store.phase.isConnected)
        Button("Delete Channel", systemImage: "trash", role: .destructive) {
            if let target = store.target { management.present(.deleteChannel(target)) }
        }
        .disabled(!store.phase.isConnected)
    }

    private var overviewButton: some View {
        Button("Overview", systemImage: "sidebar.trailing") {
            interaction.isInspectorPresented.toggle()
        }
        .disabled(store.phase == .deleted)
    }
}

/// The channel's name as a floating glass button in the title's place, like the Mac's, which opens
/// Channel Actions. The system title menu would add a chevron and its own bar.
private struct ChannelTitleMenu<Content: View>: View {
    let title: String
    let subtitle: String?
    let maxWidth: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle ?? "")
        .accessibilityHint("Shows channel actions")
    }
}

struct ChannelReaderVisibility {
    let artifactRequested: Bool
    let imageRequested: Bool
    let compactOverviewRequested: Bool
    let compactOverviewPresented: Bool

    var requested: Bool { artifactRequested || imageRequested }

    var isVisible: Bool {
        requested && !compactOverviewRequested && !compactOverviewPresented
    }
}

extension EnvironmentValues {
    /// Whether bar items stand in the system's vertical bar, as on the folded iPhone Duo. iOS 27.0 has none.
    var usesVerticalToolbar: Bool {
        if #available(iOS 27.1, *) { toolbarVerticalEdge != nil } else { false }
    }
}
