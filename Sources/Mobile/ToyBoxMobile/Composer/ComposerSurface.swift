import ToyBoxClient
import ToyBoxKit
import PhotosUI
import SwiftUI
import ToyBoxUI
import UniformTypeIdentifiers

struct ComposerSurface: View {
    @Bindable var session: ComposerSession
    @Environment(AppModel.self) private var model
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ManagementPresenter.self) private var management
    @Environment(Overview.self) private var overviewPresentation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.softwareKeyboardIsVisible) private var keyboardIsVisible
    @ViewState private var showPhotos = false
    @ViewState private var showFiles = false
    @ViewState private var reattachingImageID: UUID?
    @ViewState private var reattachment: Task<Void, Never>?
    @ViewState private var photoItems: [PhotosPickerItem] = []
    @ViewState private var dragging = false

    private var draft: ComposerDraft { session.draft }
    private var store: ChannelStore { session.store }
    private var composer: ChannelComposerSession { session.composer }
    private var dictation: Dictation { session.dictation }
    private var editor: ComposerEditor { session.editor }
    private var draftID: ObjectIdentifier { ObjectIdentifier(draft) }
    private var isConnecting: Bool { store.phase == .connecting }
    private var isReaderCovered: Bool {
        interaction.isArtifactViewerPresented || overviewPresentation.isCompactSheetPresented
            || (sizeClass == .compact && interaction.isInspectorPresented)
    }
    private var canRestoreReaderFocus: Bool {
        scenePhase == .active && model.isActive && model.selectedStore === store
            && model.visibleChannel == store.target && store.phase != .deleted
            && !model.isCovered && management.flow == nil && !showPhotos && !showFiles
            && !(sizeClass == .compact && interaction.isInspectorPresented)
    }
    private var canPresentRequestPreview: Bool {
        canRestoreReaderFocus && !isReaderCovered
    }
    private var mentionQuery: AgentMentions.Query? { session.mentionQuery }
    private var choices: [AgentMentions.Choice] { session.mentionChoices }
    private var hasNotices: Bool {
        draft.error != nil || draft.isOverLimit || session.isLoadingImages
            || store.phase == .deleted
            || dictation.notice != nil
    }

    var body: some View {
        container
        .padding(.horizontal, sizeClass == .compact ? 12 : 16)
        .padding(.bottom, ComposerBottomSpacing.value(
            compact: sizeClass == .compact, keyboardVisible: keyboardIsVisible))
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { session.mentionBarHeight = $0 }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, matching: .images,
                      preferredItemEncoding: .current)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image],
                      allowsMultipleSelection: reattachingImageID == nil) { [draft] result in
            switch result {
            case .success(let urls):
                if let id = reattachingImageID {
                    if let url = urls.first {
                        reattachment?.cancel()
                        reattachment = Task { _ = await draft.reattachImage(id: id, from: url) }
                    }
                } else {
                    draft.attachFiles(urls)
                }
            case .failure(let error): draft.error = "Images could not be attached: \(error.localizedDescription)"
            }
            reattachingImageID = nil
            restoreFocus()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            let session = session
            Task { await session.importPhotos(items) }
        }
        .onChange(of: showPhotos) { _, presented in if !presented { restoreFocus() } }
        .onChange(of: showFiles) { _, presented in if !presented { restoreFocus() } }
        .onChange(of: management.flow?.id) { _, id in if id == nil { restoreFocus() } }
        .onChange(of: isReaderCovered, initial: true) { wasCovered, covered in
            if covered { dictation.deactivate() }
            else if wasCovered { Task { await dictation.refreshLanguageSupport() } }
            editor.setReaderCovered(covered, canRestoreFocus: canRestoreReaderFocus && !interaction.isRequestPreviewPresented)
        }
        .onChange(of: interaction.isRequestPreviewPresented) { _, covered in
            if !covered { restoreFocus() }
        }
        .onChange(of: mentionQuery) { _, _ in
            session.dismissedMention = nil
            session.mentionHighlight = choices.first?.id
        }
        .onChange(of: interaction.pendingComposerFocusRequest, initial: true) { _, token in
            guard let token else { return }
            interaction.consumeComposerFocusRequest(token)
            editor.focus()
        }
        .onChange(of: interaction.replyRequest?.token) { _, _ in
            guard let reply = interaction.replyRequest else { return }
            session.reply(to: reply.agent)
        }
        .onChange(of: draft.revision) { _, revision in
            registerDraft()
            dictation.draftChanged(to: revision)
        }
        .onChange(of: store.roster.map(\.name), initial: true) { _, names in
            dictation.contextualStrings = ["Lead", "Everyone"] + names
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { dictation.deactivate() }
        }
        .onAppear {
            registerDraft()
        }
        .onDisappear {
            reattachment?.cancel()
            dictation.deactivate()
        }
        .task(id: scenePhase) {
            if scenePhase == .active, !isReaderCovered { await dictation.refreshLanguageSupport() }
        }    }

    private var container: some View {
        VStack(spacing: 0) {
            if hasNotices || !draft.images.isEmpty {
                if dynamicTypeSize.isAccessibilitySize {
                    ComposerUpperRegion { accessories }
                } else {
                    ViewThatFits(in: .vertical) {
                        accessories
                        ScrollView { accessories }
                            .scrollBounceBehavior(.basedOnSize)
                    }
                }
            }
            ZStack(alignment: .topLeading) {
                if draft.text.isEmpty && !dictation.hasWords {
                    ComposerPlaceholder(isListening: dictation.isListening)
                        .padding(.horizontal, NativeComposerInput.textInsets.left)
                        .padding(.top, NativeComposerInput.textInsets.top)
                        .accessibilityHidden(true)
                }
                NativeComposerInput(
                    text: Bindable(draft).text, editor: editor, completionIsVisible: !choices.isEmpty,
                    onSend: send, onCompletionKey: { session.handleMentionKey($0, using: management) },
                    onPasteImages: { providers in for provider in providers { draft.attachProvider(provider) } },
                    onEscape: dictation.phase == .idle ? nil : {
                        Task { await dictation.stop(.escape) }
                    },
                    dictation: dictation
                )
            }
            .padding(.bottom, 6)
            .layoutPriority(1)
            controls.padding(.horizontal, 8).padding(.bottom, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { session.mentionListMaxHeight = $0 }
        .overlay {
            if dragging {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 2).allowsHitTesting(false)
            }
        }

        .onDrop(of: [UTType.fileURL, .image], isTargeted: $dragging) { providers in
            providers.map { draft.attachProvider($0) }.contains(true)
        }
    }

    private var accessories: some View {
        VStack(spacing: 0) {
            if hasNotices { notices.padding(.vertical, 8) }
            if !draft.images.isEmpty {
                ComposerImageStrip(draft: draft) { id in
                    session.preparePresentation()
                    reattachingImageID = id
                    showFiles = true
                }
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(showsAudienceLabel: true, showsRequestLabel: true)
            actionRow(showsAudienceLabel: false, showsRequestLabel: true)
            actionRow(showsAudienceLabel: false, showsRequestLabel: false)
        }
    }

    private func actionRow(showsAudienceLabel: Bool, showsRequestLabel: Bool) -> some View {
        HStack(spacing: 4) {
            attachmentMenu
            context(showsAudienceLabel: showsAudienceLabel, showsRequestLabel: showsRequestLabel)
            Spacer(minLength: 0)
            ComposerDictateButton(dictation: dictation)
            sendButton
        }
    }

    private func context(showsAudienceLabel: Bool, showsRequestLabel: Bool) -> some View {
        HStack(spacing: 4) {
            AudiencePill(
                text: draft.text,
                agents: store.roster,
                acknowledgesRequest: store.requestSequence != nil,
                showsLabel: showsAudienceLabel
            )
            if let request = store.request {
                ComposerRequestButton(
                    request: request,
                    store: store,
                    allowsPresentation: canPresentRequestPreview,
                    showsLabel: showsRequestLabel,
                    willPresent: session.preparePresentation,
                    didDismiss: restoreFocus
                )
                    .id(request.sequence)
                    .id(draftID)
            }
        }
    }

    private var attachmentMenu: some View {
        Menu {
            Button("Choose Photos", systemImage: "photo.on.rectangle") { session.preparePresentation(); showPhotos = true }
            Button("Choose Files", systemImage: "folder") {
                session.preparePresentation()
                reattachingImageID = nil
                showFiles = true
            }
        } label: {
            ComposerAttachmentLabel()
        }
        .accessibilityLabel("Attach images")
        .accessibilityShowsLargeContentViewer()
    }

    private var sendButton: some View {
        Button(action: send) {
            Group {
                if session.dictation.holdsSend || isConnecting {
                    ProgressView().frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 32, height: 32)
                        .background(session.canSend ? Color.accentColor : Color(uiColor: .quaternaryLabel),
                                    in: Circle())
                        .foregroundStyle(session.canSend ? .white : .secondary)
                }
            }
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.canSend || scenePhase != .active)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(isConnecting ? "Connecting" : "Send message")
        .accessibilityShowsLargeContentViewer()
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = draft.error {
                notice(draft.isSavedLocally ? error : "Couldn't save this draft on this iPhone. \(error)")
                if !draft.isSavedLocally { Button("Retry Saving Draft") { draft.retrySave() } }
            }
            if draft.isOverLimit { notice("Messages are limited to 12,000 characters.") }
            if session.isLoadingImages { Label("Reading images", systemImage: "photo") }
            if let notice = dictation.notice {
                switch notice {
                case .failed, .unsent: self.notice(notice.text)
                case .downloading: Label(notice.text, systemImage: "arrow.down.circle")
                case .noMicrophone: Label(notice.text, systemImage: "mic.slash")
                }
            }
            if store.phase == .deleted {
                Label("This channel was deleted. Copy your draft somewhere safe.", systemImage: "trash")
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private func notice(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        }
    }

    private func send() {
        guard scenePhase == .active, session.canSend else { return }
        Task { await session.send() }
    }

    private func restoreFocus() {
        guard !interaction.isRequestPreviewPresented else { return }
        if scenePhase == .active { Task { await dictation.refreshLanguageSupport() } }
        if session.restoresFocusAfterPresentation && canPresentRequestPreview { editor.focus() }
        session.restoresFocusAfterPresentation = false
    }
    private func registerDraft() {
        interaction.hasDraft = draft.hasContent
        interaction.copyDraft = { UIPasteboard.general.string = draft.text }
    }
}

/// Drawn over ConversationView, whose UIView already covers this rect, so taps hit the list instead of
/// the working capsule. Bottom padding is the composer bar plus 8, matching the old overlay.
struct ComposerMentionList: View {
    @Bindable var session: ComposerSession
    @Environment(ManagementPresenter.self) private var management
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewState private var completionHeight: CGFloat = 264

    private var store: ChannelStore { session.store }
    private var choices: [AgentMentions.Choice] { session.mentionChoices }

    var body: some View {
        if !choices.isEmpty {
            let barHeight = session.mentionBarHeight
            completion
                .padding(.horizontal, 12)
                .padding(.bottom, 8 + barHeight)
                .padding(.horizontal, sizeClass == .compact ? 12 : 16)
        }
    }

    private var completion: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(choices) { choice in
                        completionRow(choice)
                            .overlay(alignment: .bottom) {
                                if choice.id != choices.last?.id {
                                    Divider().padding(.leading, 46)
                                }
                            }
                            .id(choice.id)
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { completionHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer-mention-list")
            .onChange(of: session.mentionHighlight) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(maxWidth: 320)
        .frame(maxHeight: min(264, completionHeight, session.mentionListMaxHeight > 0 ? session.mentionListMaxHeight : 264))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func completionRow(_ choice: AgentMentions.Choice) -> some View {
        Button { session.acceptMention(choice, using: management) } label: {
            HStack(spacing: 10) {
                if let agent = choice.agent { AgentAvatarView(agent: agent, size: 24) }
                else {
                    Image(systemName: choice.isCreate ? "person.badge.plus" : "person.3")
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.isCreate ? "Create \(choice.name)" : choice.name).font(.headline).lineLimit(1)
                    Text(choice.detail).font(.caption).foregroundStyle(ChannelInk.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .disabled(choice.isCreate && !store.phase.isConnected)
        .accessibilityIdentifier("composer-mention-\(choice.id)")
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(session.mentionHighlight == choice.id ? Color(uiColor: .secondarySystemFill) : .clear)
        .contextMenu {
            if let agent = choice.agent, choice.isMember {
                Button("Edit Agent") {
                    session.presentEdit(agentId: agent.id, using: management)
                }
                .disabled(!store.phase.isConnected)
            }
        }
    }

}

struct ComposerPlaceholder: View {
    let isListening: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(isListening ? "Listening\u{2026}" : "Message your team")
                .fixedSize(horizontal: true, vertical: false)
            Text(isListening ? "Listening" : "Message")
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.body)
        .foregroundStyle(ChannelInk.secondary)
    }
}

struct ComposerAttachmentLabel: View {
    var body: some View {
        Image(systemName: "photo.badge.plus")
            .font(.system(size: 17))
            .foregroundStyle(Color.primary)
            .frame(width: 44, height: 44)
    }
}

struct ComposerUpperRegion<Content: View>: View {
    @ViewState private var contentHeight: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0) { content }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: contentHeight)
    }
}

enum ComposerBottomSpacing {
    static func value(compact: Bool, keyboardVisible: Bool) -> CGFloat {
        compact && !keyboardVisible ? 0 : 8
    }
}
