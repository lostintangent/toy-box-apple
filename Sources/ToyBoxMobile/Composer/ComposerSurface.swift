import ChannelClient
import ChannelKit
import PhotosUI
import SwiftUI
import ToyBoxUI
import UniformTypeIdentifiers

struct ComposerSurface: View {
    @Bindable var session: ComposerSession
    let showsTray: Bool
    @Environment(AppModel.self) private var model
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ManagementPresenter.self) private var management
    @Environment(OverviewPresentation.self) private var overviewPresentation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @ViewState private var showPhotos = false
    @ViewState private var showFiles = false
    @ViewState private var reattachingImageID: UUID?
    @ViewState private var reattachment: Task<Void, Never>?
    @ViewState private var photoItems: [PhotosPickerItem] = []
    @ViewState private var restoresFocus = false
    @ViewState private var dragging = false
    @ViewState private var highlightedChoice: String?
    @ViewState private var dismissedCompletion: ChannelMentionContext?
    @ViewState private var completionHeight: CGFloat = 264
    @ViewState private var completionViewportHeight: CGFloat = 0
    @ViewState private var connectionGrace = ConnectGrace()

    private var draft: ComposerDraft { session.draft }
    private var store: ChannelStore { session.store }
    private var composer: ChannelComposerSession { session.composer }
    private var dictation: ComposerDictation { session.dictation }
    private var editor: ComposerEditorState { session.editor }
    private var draftID: ObjectIdentifier { ObjectIdentifier(draft) }
    private var isReaderCovered: Bool {
        interaction.isArtifactViewerPresented || overviewPresentation.isCompactSheetPresented
            || (sizeClass == .compact && interaction.isInspectorPresented)
    }
    private var canRestoreReaderFocus: Bool {
        scenePhase == .active && model.isActive && model.selectedStore === store
            && model.visibleChannelID == store.id && store.phase != .deleted
            && !model.isSettingsPresented && management.flow == nil && !showPhotos && !showFiles
            && !(sizeClass == .compact && interaction.isInspectorPresented)
    }
    private var canPresentRequestPreview: Bool {
        canRestoreReaderFocus && !isReaderCovered
    }
    private var mentionContext: ChannelMentionContext? {
        guard editor.isFocused, !editor.hasMarkedText, !dictation.isSessionActive else { return nil }
        return .match(text: draft.text, selection: editor.selection)
    }
    private var choices: [ChannelMentionChoice] {
        guard let context = mentionContext, context != dismissedCompletion else { return [] }
        return ChannelMentionChoice.choices(matching: context.query, among: store.roster)
    }
    private var hasNotices: Bool {
        draft.error != nil || composer.error != nil || store.attemptPersistenceError != nil
            || draft.text.utf16.count > 12_000 || session.isLoadingImages
            || connectionGrace.explains(store.phase, for: draftID) || composer.attempt?.canRetry == true
            || dictation.notice != nil
    }

    var body: some View {
        container
        .overlay(alignment: .topLeading) {
            if !choices.isEmpty {
                completion
                    .padding(.horizontal, 12)
                    .offset(y: -completionViewportHeight - 8)
            }
        }
        .padding(.horizontal, sizeClass == .compact ? 12 : 16)
        .frame(maxWidth: 720)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
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
        .onChange(of: mentionContext) { _, _ in
            dismissedCompletion = nil
            highlightedChoice = choices.first?.id
        }
        .onChange(of: interaction.composerFocusRequest) { _, _ in editor.focus() }
        .onChange(of: interaction.replyRequest?.token) { _, _ in
            guard let reply = interaction.replyRequest else { return }
            session.reply(to: reply.agent, sequence: reply.sequence)
        }
        .onChange(of: interaction.editSendAttemptRequest?.token) { _, _ in
            guard let id = interaction.editSendAttemptRequest?.id,
                  let attempt = store.sendAttempts.first(where: { $0.id == id }) else { return }
            session.edit(attempt)
        }
        .onChange(of: composer.isConfirmed) { _, confirmed in
            if confirmed { composer.reconcile(); interaction.jumpToLatest() }
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
        .onAppear { composer.reconcile(); registerDraft() }
        .onDisappear {
            reattachment?.cancel()
            dictation.deactivate()
        }
        .task(id: scenePhase) {
            if scenePhase == .active, !isReaderCovered { await dictation.refreshLanguageSupport() }
        }
        .task(id: store.phase) { await connectionGrace.watch(store.phase, for: draftID) }
        .confirmationDialog("Keep your current draft?", isPresented: Binding(
            get: { composer.pendingEdit != nil },
            set: { if !$0 { composer.pendingEdit = nil } }
        ), titleVisibility: .visible) {
            Button("Append Unsent Message") { session.appendPendingEdit() }
            Button("Cancel", role: .cancel) { composer.pendingEdit = nil }
        } message: {
            Text(ChannelComposerSession.appendExplanation)
        }
    }

    private var container: some View {
        VStack(spacing: 0) {
            if showsTray { ComposerTaskProgress(store: store, showTasks: showTasks) }
            if dynamicTypeSize.isAccessibilitySize {
                ComposerUpperRegion {
                    accessories
                    context.padding(.horizontal, 8)
                }
            } else if hasNotices || composer.replySource != nil || !draft.images.isEmpty {
                ViewThatFits(in: .vertical) {
                    accessories
                    ScrollView { accessories }
                        .scrollBounceBehavior(.basedOnSize)
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
                    onSend: send, onCompletionKey: handleCompletionKey,
                    onPasteImages: { providers in for provider in providers { draft.attachProvider(provider) } },
                    onEscape: composer.replySource == nil && dictation.phase == .idle ? nil : {
                        if dictation.phase != .idle { Task { await dictation.stop(.escape) } }
                        else { composer.replySource = nil }
                    },
                    dictation: dictation
                )
            }
            .padding(.bottom, 6)
            .layoutPriority(1)
            controls.padding(.horizontal, 8).padding(.bottom, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassEffect(.regular.tint(Color(uiColor: .systemBackground).opacity(0.3)),
                     in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
            if let source = composer.replySource {
                HStack(spacing: 4) {
                    Button { interaction.reveal(sequence: source.sequence) } label: {
                        Label("Replying to \(source.name)", systemImage: "arrowshape.turn.up.left")
                            .foregroundStyle(Color.primary)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { composer.replySource = nil } label: {
                        Image(systemName: "xmark").foregroundStyle(Color.primary).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Dismiss reply context")
                }
                .font(.footnote)
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .padding(.leading, 12)
            }
            if !draft.images.isEmpty {
                ComposerImageStrip(draft: draft) { id in
                    preparePresentation()
                    reattachingImageID = id
                    showFiles = true
                }
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            actionControls
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    attachmentMenu
                    context
                    Spacer(minLength: 0)
                    ComposerDictateButton(dictation: dictation)
                    sendButton
                }
                VStack(spacing: 0) {
                    HStack(spacing: 4) { context; Spacer(minLength: 0) }.frame(minHeight: 44)
                    actionControls
                }
            }
        }
    }

    private var actionControls: some View {
        HStack(spacing: 4) {
            attachmentMenu
            Spacer(minLength: 0)
            ComposerDictateButton(dictation: dictation)
            sendButton
        }
    }

    private var context: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(ComposerContextLayout()) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            ComposerAudienceView(text: draft.text, agents: store.roster,
                                 acknowledgesRequest: store.requestSequence != nil)
            if let request = store.request {
                ComposerRequestButton(request: request, allowsPresentation: canPresentRequestPreview,
                                      wrapsLabel: dynamicTypeSize.isAccessibilitySize,
                                      willPresent: preparePresentation, didDismiss: restoreFocus)
                    .id(request.sequence)
                    .id(draftID)
            }
        }
    }

    private var attachmentMenu: some View {
        Menu {
            Button("Choose Photos", systemImage: "photo.on.rectangle") { preparePresentation(); showPhotos = true }
            Button("Choose Files", systemImage: "folder") {
                preparePresentation()
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
                if session.isFinalizingDictation || composer.isSubmitting || composer.attempt?.phase == .sending {
                    ProgressView().frame(width: 32, height: 32)
                } else {
                    Image(systemName: composer.attempt?.canRetry == true ? "arrow.clockwise" : "arrow.up")
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
        .accessibilityLabel(composer.attempt?.canRetry == true ? "Send Again" : "Send message")
        .accessibilityShowsLargeContentViewer()
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = draft.error {
                notice(draft.isSavedLocally ? error : "Couldn't save this draft on this iPhone. \(error)")
                if !draft.isSavedLocally { Button("Retry Saving Draft") { draft.retrySave() } }
            }
            if let error = composer.error { notice(error) }
            if let error = store.attemptPersistenceError { notice(error) }
            if draft.text.utf16.count > 12_000 { notice("Messages are limited to 12,000 characters.") }
            if session.isLoadingImages { Label("Reading images", systemImage: "photo") }
            if let notice = dictation.notice {
                switch notice {
                case .failed, .unsent: self.notice(notice.text)
                case .downloading: Label(notice.text, systemImage: "arrow.down.circle")
                case .noMicrophone: Label(notice.text, systemImage: "mic.slash")
                }
            }
            if connectionGrace.explains(store.phase, for: draftID) {
                Label(store.phase == .deleted ? "This channel was deleted. Copy your draft somewhere safe."
                      : "Reconnect before sending so the audience is current.", systemImage: "wifi.slash")
                if store.phase != .deleted { Button("Reconnect") { store.reconnect() } }
            }
            if let attempt = composer.attempt, attempt.canRetry {
                Label(attempt.phase == .notSent ? "\(attempt.phase.label). \(attempt.error ?? "Try sending again.")"
                      : "\(attempt.phase.label). It may have arrived.", systemImage: "exclamationmark.circle")
                Button("Edit") { editor.focus() }
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
            .onChange(of: highlightedChoice) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(maxWidth: 320)
        .frame(maxHeight: min(264, completionHeight))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { completionViewportHeight = $0 }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .glassEffect(.regular.tint(Color(uiColor: .systemBackground).opacity(0.3)),
                     in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func completionRow(_ choice: ChannelMentionChoice) -> some View {
        Button { accept(choice) } label: {
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
        .disabled(choice.isCreate && !store.phase.isLive)
        .accessibilityIdentifier("composer-mention-\(choice.id)")
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(highlightedChoice == choice.id ? Color(uiColor: .secondarySystemFill) : .clear)
        .contextMenu {
            if let agent = choice.agent, choice.isMember {
                Button("Edit Agent") {
                    preparePresentation()
                    management.present(.editMember(channelId: store.id, agentId: agent.id))
                }
                .disabled(!store.phase.isLive)
            }
        }
    }

    private func handleCompletionKey(_ key: ComposerCompletionKey) -> Bool {
        let choices = choices
        guard !choices.isEmpty else { return false }
        let index = choices.firstIndex { $0.id == highlightedChoice } ?? 0
        switch key {
        case .previous: highlightedChoice = choices[max(0, index - 1)].id
        case .next: highlightedChoice = choices[min(choices.count - 1, index + 1)].id
        case .accept: accept(choices[index])
        case .dismiss: dismissedCompletion = mentionContext
        }
        return true
    }

    private func accept(_ choice: ChannelMentionChoice) {
        guard let context = mentionContext else { return }
        if choice.isCreate {
            guard store.phase.isLive else { return }
            dismissedCompletion = context
            preparePresentation()
            management.present(.addMember(channelId: store.id, name: choice.name))
        } else {
            editor.replace(context.range, with: "\(choice.handle) ")
        }
    }

    private func send() {
        guard scenePhase == .active, session.canSend else { return }
        interaction.jumpToLatest()
        Task { if await session.send() { interaction.jumpToLatest() } }
    }

    private func showTasks() {
        if sizeClass == .compact { editor.setReaderCovered(true, canRestoreFocus: false) }
        interaction.showOverviewTasks()
    }

    private func preparePresentation() {
        restoresFocus = editor.isFocused
        dictation.deactivate()
    }
    private func restoreFocus() {
        guard !interaction.isRequestPreviewPresented else { return }
        if scenePhase == .active { Task { await dictation.refreshLanguageSupport() } }
        if restoresFocus && canPresentRequestPreview { editor.focus() }
        restoresFocus = false
    }
    private func registerDraft() {
        interaction.hasDraft = draft.hasContent
        interaction.copyDraft = { UIPasteboard.general.string = draft.text }
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

struct ComposerContextLayout: Layout {
    private let spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measurement(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = measurement(proposal: .init(width: bounds.width, height: nil), subviews: subviews)
        var origin = bounds.origin
        for (subview, size) in zip(subviews, measured.children) {
            if measured.isHorizontal {
                subview.place(at: .init(x: origin.x, y: bounds.midY), anchor: .leading,
                              proposal: .init(size))
                origin.x += size.width + spacing
            } else {
                subview.place(at: origin, anchor: .topLeading,
                              proposal: .init(width: bounds.width, height: size.height))
                origin.y += size.height + spacing
            }
        }
    }

    private func measurement(
        proposal: ProposedViewSize, subviews: Subviews
    ) -> (size: CGSize, children: [CGSize], isHorizontal: Bool) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let gaps = CGFloat(max(0, ideal.count - 1)) * spacing
        let idealWidth = ideal.reduce(0) { $0 + $1.width } + gaps
        let width = max(0, proposal.width ?? idealWidth)
        if idealWidth <= width {
            return (.init(width: idealWidth, height: ideal.map(\.height).max() ?? 0), ideal, true)
        }
        let fitted = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)) }
        return (.init(width: width, height: fitted.reduce(0) { $0 + $1.height } + gaps), fitted, false)
    }
}
