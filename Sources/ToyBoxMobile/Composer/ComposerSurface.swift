import ChannelClient
import ChannelKit
import PhotosUI
import SwiftUI
import ToyBoxUI
import UniformTypeIdentifiers

struct ComposerSurface: View {
    @Bindable var session: ComposerSession
    @Environment(AppModel.self) private var model
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ManagementPresenter.self) private var management
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var showPhotos = false
    @ViewState private var showFiles = false
    @ViewState private var photoItems: [PhotosPickerItem] = []
    @ViewState private var restoresFocus = false
    @ViewState private var dragging = false
    @ViewState private var highlightedChoice: String?
    @ViewState private var dismissedCompletion: ChannelMentionContext?
    @ViewState private var connectionGrace = ConnectGrace()

    private var draft: ComposerDraft { session.draft }
    private var store: ChannelStore { session.store }
    private var composer: ChannelComposerSession { session.composer }
    private var editor: ComposerEditorState { session.editor }
    private var draftID: ObjectIdentifier { ObjectIdentifier(draft) }
    private var canRestoreReaderFocus: Bool {
        scenePhase == .active && model.isActive && model.selectedStore === store
            && model.visibleChannelID == store.id && store.phase != .deleted
            && !model.isSettingsPresented && management.flow == nil && !showPhotos && !showFiles
            && !(sizeClass == .compact && interaction.isInspectorPresented)
    }
    private var mentionContext: ChannelMentionContext? {
        guard editor.isFocused, !editor.hasMarkedText else { return nil }
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !choices.isEmpty { completion.padding(.horizontal, 12) }
            container
        }
        .padding(.horizontal, sizeClass == .compact ? 12 : 16)
        .frame(maxWidth: 720)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, matching: .images,
                      preferredItemEncoding: .current)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): draft.attachFiles(urls)
            case .failure(let error): draft.error = "Images could not be attached: \(error.localizedDescription)"
            }
            restoreFocus()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            let session = session
            Task { await session.importPhotos(items) }
        }
        .onChange(of: showPhotos) { _, presented in if !presented { restoreFocus() } }
        .onChange(of: management.flow?.id) { _, id in if id == nil { restoreFocus() } }
        .onChange(of: interaction.isArtifactViewerPresented, initial: true) { _, covered in
            editor.setReaderCovered(covered, canRestoreFocus: canRestoreReaderFocus)
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
        .onChange(of: draft.revision) { _, _ in registerDraft() }
        .onAppear { composer.reconcile(); registerDraft() }
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
                ComposerImageStrip(draft: draft) { preparePresentation(); showFiles = true }
            }
            ZStack(alignment: .topLeading) {
                if draft.text.isEmpty {
                    Text("Message your team")
                        .font(.body).foregroundStyle(Color.primary).lineLimit(1)
                        .padding(.horizontal, 12).padding(.top, 10).accessibilityHidden(true)
                }
                NativeComposerInput(
                    text: Bindable(draft).text, editor: editor, completionIsVisible: !choices.isEmpty,
                    onSend: send, onCompletionKey: handleCompletionKey,
                    onPasteImages: { providers in for provider in providers { draft.attachProvider(provider) } },
                    onEscape: composer.replySource == nil ? nil : { composer.replySource = nil }
                )
            }
            .padding(.bottom, 6)
            controls.padding(.horizontal, 8).padding(.bottom, 6)
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

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                attachmentMenu
                context
                Spacer(minLength: 0)
                sendButton
            }
            VStack(spacing: 0) {
                HStack(spacing: 4) { context; Spacer(minLength: 0) }.frame(minHeight: 44)
                HStack(spacing: 4) { attachmentMenu; Spacer(minLength: 0); sendButton }
            }
        }
    }

    private var context: some View {
        HStack(spacing: 4) {
            ComposerAudienceView(text: draft.text, agents: store.roster,
                                 acknowledgesRequest: store.requestSequence != nil)
            if let request = store.request { inputNeeded(request) }
        }
    }

    private var attachmentMenu: some View {
        Menu {
            Button("Choose Photos", systemImage: "photo.on.rectangle") { preparePresentation(); showPhotos = true }
            Button("Choose Files", systemImage: "folder") { preparePresentation(); showFiles = true }
        } label: {
            Image(systemName: "photo.badge.plus").foregroundStyle(Color.primary).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Attach images")
    }

    private var sendButton: some View {
        Button(action: send) {
            Group {
                if composer.isSubmitting || composer.attempt?.phase == .sending {
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

    private func inputNeeded(_ request: ChannelMessage) -> some View {
        Button { interaction.reveal(sequence: request.sequence) } label: {
            Label {
                Text("Input Needed").foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(ChannelAttentionStyle.color(for: .waiting, in: colorScheme))
            }
            .lineLimit(1).frame(minHeight: 44)
        }
        .font(.footnote)
        .buttonStyle(.borderless)
        .contextMenu {
            Button(store.historyError == nil ? "Reveal in Conversation" : "Retry Reveal") {
                interaction.reveal(sequence: request.sequence)
            }
        } preview: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Input Needed").font(.headline)
                ScrollView { Text(request.text).frame(maxWidth: .infinity, alignment: .leading) }
                if let error = store.historyError { Text(error).font(.footnote) }
            }
            .padding(16).frame(width: 320)
        }
        .accessibilityLabel("Input needed. Reveal the unanswered request.")
    }

    private var completion: some View {
        ScrollViewReader { proxy in
            List(selection: $highlightedChoice) {
                ForEach(choices) { choice in
                    completionRow(choice).tag(choice.id).id(choice.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: highlightedChoice) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 320)
        .frame(height: min(264, CGFloat(choices.count) * 56))
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
                    Text(choice.isCreate ? "Create \(choice.name)" : choice.name).font(.headline)
                    Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .disabled(choice.isCreate && !store.phase.isLive)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
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

    private func preparePresentation() { restoresFocus = editor.isFocused }
    private func restoreFocus() {
        if restoresFocus { editor.focus() }
        restoresFocus = false
    }
    private func registerDraft() {
        interaction.hasDraft = draft.hasContent
        interaction.copyDraft = { UIPasteboard.general.string = draft.text }
    }
}
