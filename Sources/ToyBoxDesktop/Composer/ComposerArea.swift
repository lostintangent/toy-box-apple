import AppKit
import ChannelClient
import ChannelKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerArea: View {
    let store: ChannelStore
    @Environment(\.windowSnapshot) private var snapshot
    @ViewState private var snapshotDraft = ComposerDraft()

    /// One composer serves the window. A switch hands it the next channel's draft, so its text view
    /// is kept rather than rebuilt.
    var body: some View {
        ChannelComposer(store: store, draft: snapshot == nil
                        ? .shared(serverURL: store.api.baseURL, channelID: store.id) : snapshotDraft)
    }
}

/// Opens the image picker. Like Dictate, the whole 28pt circle takes clicks and is its accessibility frame.
struct AttachImagesButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "photo.badge.plus")
                .frame(width: 28, height: 28)
                .contentShape([.interaction, .accessibility], Circle())
        }
        .buttonStyle(.borderless)
        .help("Attach images")
        .accessibilityLabel("Attach images")
    }
}

/// Pending images above the input. It scrolls sideways when they overflow, at one height for every
/// scroller style.
struct ComposerImageStrip: View {
    let draft: ComposerDraft

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(draft.images) { image in
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Group {
                                if let thumbnail = image.image {
                                    Image(nsImage: thumbnail).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                }
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            Button { draft.removeImage(id: image.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.black.opacity(0.7))
                                    .padding(2)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(image.name)")
                        }
                        Text(image.name).font(.system(size: 10)).lineLimit(1).frame(width: 68)
                    }
                    .help(image.image == nil ? "\(image.name) must be reattached" : image.name)
                }
            }
            .padding(12)
        }
        // `.hidden` still shows a legacy scroller for mouse users, which would grow the strip 17pt.
        .scrollIndicators(.never)
    }
}

/// Separates the composer's notices and tray from the input.
struct ComposerHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.horizontal, 12)
            .accessibilityHidden(true)
    }
}

private struct ChannelComposer: View {
    let store: ChannelStore
    @Bindable var draft: ComposerDraft
    @Environment(AppModel.self) private var app
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ManagementPresenter.self) private var management
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.windowSnapshot) private var snapshot
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewState private var inputHeight: CGFloat = 44
    @ViewState private var isFocused = false
    @ViewState private var isDragging = false
    @ViewState private var showPicker = false
    @ViewState private var focusRequest = UUID()
    @ViewState private var requestPreview = false
    @ViewState private var requestHoverTask: Task<Void, Never>?
    /// A send in flight and a failure the store didn't record stay with the draft they came from,
    /// so a switch doesn't hold back or misreport the next channel's Send.
    @ViewState private var submitting: ObjectIdentifier?
    @ViewState private var unrecordedFailure: (draft: ObjectIdentifier, message: String)?
    @ViewState private var pendingEdit: ChannelSendAttempt?
    @ViewState private var showAppendConfirmation = false
    @ViewState private var dictation = ComposerDictation()
    @ViewState private var sendsAfterDictation = false
    @ViewState private var connectGrace = ConnectGrace()

    /// The draft's identity. There's one draft per server and channel.
    private var draftID: ObjectIdentifier { ObjectIdentifier(draft) }

    private var explainsConnection: Bool { connectGrace.explains(store.phase, for: draftID) }

    private struct ConnectionWait: Equatable {
        let draft: ObjectIdentifier
        let isConnecting: Bool
    }
    private var isSubmitting: Bool { submitting == draftID }
    private var submissionError: String? {
        unrecordedFailure.flatMap { $0.draft == draftID ? $0.message : nil }
    }

    private var canSend: Bool {
        store.phase.isLive && !store.isSending && !isSubmitting && (draft.hasContent || dictation.hasWords)
            && !draft.isLoadingImages && !draft.hasUnreadableImage && draft.text.utf16.count <= 12_000
            && associatedAttempt?.phase != .confirmed
    }

    private var associatedAttempt: ChannelSendAttempt? {
        guard let id = draft.sendAttemptID else { return nil }
        return store.sendAttempts.first { $0.id == id }
    }

    private var failureFeedback: ComposerFailureFeedback? {
        store.lastSendFailure.map { failure in
            .init(id: failure.id, message: "\(failure.phase.label). \(failure.error)")
        }
    }

    /// Whether the message this draft sent has arrived. It reads `messages` only while a send is
    /// pending, so other messages don't re-render the composer.
    private var sentMessageArrived: Bool {
        guard let id = draft.sendAttemptID else { return false }
        return store.messages.reversed().contains { $0.id == id }
    }

    private var placeholder: String {
        if store.requestSequence != nil {
            return "Reply to Lead, or @mention an agent"
        }
        return "Message the team, or @mention an agent"
    }

    private var isOverLimit: Bool { draft.text.utf16.count > 12_000 }
    private var hasNotices: Bool {
        draft.error != nil || store.attemptPersistenceError != nil || submissionError != nil
            || explainsConnection || isOverLimit || dictation.notice != nil
    }

    var body: some View {
        input
            .padding(.bottom, 16)
            .modifier(ConversationRail())
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): draft.attachFiles(urls)
            case .failure(let error): draft.error = "Images could not be attached: \(error.localizedDescription)"
            }
        }
        .onChange(of: interaction.composerFocusRequest) { _, _ in focusRequest = UUID() }
        .onChange(of: interaction.replyRequest?.token) { _, _ in
            guard let agent = interaction.replyRequest?.agent else { return }
            dictation.commitNow()
            let mention = "@\(agentHandleFromName(agent.name)) "
            if !draft.text.hasPrefix(mention) { draft.text = mention + draft.text }
            focusRequest = UUID()
        }
        .onChange(of: interaction.editSendAttemptRequest?.token) { _, _ in
            guard let request = interaction.editSendAttemptRequest,
                  let attempt = store.sendAttempts.first(where: { $0.id == request.id }) else { return }
            dictation.commitNow()
            if draft.hasContent && (draft.text.trimmingCharacters(in: .whitespacesAndNewlines) != attempt.content
                                    || draft.images.map(\.attachment) != attempt.attachments) {
                pendingEdit = attempt
                showAppendConfirmation = true
            } else {
                restore(attempt)
            }
        }
        .confirmationDialog("Keep your current draft?", isPresented: $showAppendConfirmation,
                            titleVisibility: .visible) {
            Button("Append Unsent Message") {
                guard let attempt = pendingEdit else { return }
                if !draft.text.isEmpty { draft.text += "\n\n" }
                draft.text += attempt.content
                for attachment in attempt.attachments {
                    guard let encoded = attachment.base64, let data = Data(base64Encoded: encoded),
                          let mimeType = attachment.mimeType else {
                        draft.error = "An image from the unsent message is unavailable. Attach it again."
                        continue
                    }
                    draft.append(.init(name: attachment.name ?? "Attached image", mimeType: mimeType, data: data))
                }
                pendingEdit = nil
                focusRequest = UUID()
            }
            Button("Cancel", role: .cancel) { pendingEdit = nil }
        } message: {
            Text("Your newer draft will not be replaced. Appending preserves both messages. Sending edited text creates a new message, and an earlier unconfirmed send may already have arrived.")
        }
        .onAppear {
            adoptDraft()
            dictation.activate()
        }
        // The text view swaps its own text, selection and undo, and commits dictation to the draft
        // it was spoken into. Transient UI that belonged to the last channel's draft closes.
        .onChange(of: draftID) {
            requestHoverTask?.cancel()
            requestPreview = false
            showPicker = false
            isDragging = false
            pendingEdit = nil
            showAppendConfirmation = false
            connectGrace.reset()
            adoptDraft()
        }
        .task(id: ConnectionWait(draft: draftID, isConnecting: ConnectGrace.isConnecting(store.phase))) {
            await connectGrace.watch(store.phase, for: draftID)
        }
        .onChange(of: draft.revision) { _, revision in
            registerDraft()
            dictation.draftChanged(to: revision)
        }
        .onChange(of: sentMessageArrived) { _, _ in reconcileDraft() }
        .onChange(of: associatedAttempt?.phase) { _, _ in reconcileDraft() }
        .onChange(of: associatedAttempt?.id) { old, new in
            if old == nil, new != nil, isSubmitting { interaction.jumpToLatest() }
        }
        .task(id: snapshot?.requestedState) {
            switch snapshot?.requestedState {
            case "composer-draft":
                draft.text = "@ada Here's the latest screenshot.\nThe draft stays with this channel.\nReady for your review."
                focusRequest = UUID()
            case "composer-mentions", "composer-mention-keys":
                draft.text = "@"
                focusRequest = UUID()
            case "composer-notices":
                draft.text = "Here's the revised entrance layout."
                draft.error = "Library sketch.heic cannot be decoded as an image. Attach a readable image file."
                snapshot?.markStateReady("composer-notices")
            case let name? where name.hasPrefix("composer-dictation"):
                await prepareDictationSnapshot(name)
            default: break
            }
        }
        .onDisappear {
            requestHoverTask?.cancel()
            dictation.deactivate()
        }
    }

    /// Drives the Dictate states with scripted platform services, or the real transcriber on a DEBUG recording.
    private func prepareDictationSnapshot(_ name: String) async {
        let words: [(String, Bool)] = [("Can you tighten the sidebar spacing", true), ("?", true),
                                       (" And check the header", false)]
        var recording = false
#if DEBUG
        recording = name == "composer-dictation-recording" && DictationSystem.recordingOverride != nil
#endif
        dictation.system = switch name {
        case _ where recording: .live
        case "composer-dictation-listening": .scripted(results: words)
        case "composer-dictation-unsent": .scripted(results: words, finishes: false)
        case "composer-dictation-download": .scripted(downloadProgress: 0.35)
        case "composer-dictation-access-off": .scripted(microphone: .denied)
        case "composer-dictation-no-microphone": .scripted(hasMicrophone: false)
        default: .scripted()
        }
        await dictation.refresh()
        switch name {
        case "composer-dictation-access-off":
            // Access is first checked by a click. The button shows it without the click's popover.
            await dictation.startTracking()
        case "composer-dictation-listening", "composer-dictation-listening-empty", "composer-dictation-download",
             "composer-dictation-recording", "composer-dictation-unsent", "composer-dictation-no-microphone":
            dictation.contextualStrings = dictationContext
            dictation.toggle()
            let deadline = ContinuousClock.now + .seconds(recording ? 20 : 5)
            while ContinuousClock.now < deadline {
                let ready = switch name {
                case "composer-dictation-listening": dictation.isListening && dictation.hasWords && !draft.text.isEmpty
                case "composer-dictation-recording", "composer-dictation-unsent":
                    dictation.hasTentativeWords && !draft.text.isEmpty
                case "composer-dictation-download": dictation.notice != nil
                case "composer-dictation-no-microphone": dictation.notice == .noMicrophone
                default: dictation.isListening && dictation.level > 0.5
                }
                if ready { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if name == "composer-dictation-unsent" {
                // Send while the scripted transcriber never finishes its final pass.
                dictation.system.finalizeTimeout = .milliseconds(300)
                await dictation.stop(.send)
            }
        default: break
        }
        snapshot?.markStateReady(name)
    }

    private var dictationContext: [String] {
        store.roster.filter { $0.deleted != true }.map(\.name) + ["Lead", "Everyone"]
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = draft.error {
                composerError(error) { draft.error = nil }
            }
            if let notice = dictation.notice {
                if case .downloading = notice {
                    Text(notice.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    composerError(notice.text) { dictation.dismissNotice() }
                }
            }
            if let error = store.attemptPersistenceError {
                composerError(error)
            }
            if let error = submissionError {
                composerError(error)
            }
            if explainsConnection {
                connectionExplanation
            }
            if isOverLimit {
                composerError("Messages are limited to 12,000 characters.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var input: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(spacing: 0) {
            if hasNotices {
                notices
                ComposerHairline()
            }
            ComposerTray(store: store)
            if !draft.images.isEmpty { ComposerImageStrip(draft: draft) }
            ZStack(alignment: .topLeading) {
                if draft.text.isEmpty && !dictation.hasWords {
                    Text(dictation.isListening ? "Listening…" : placeholder)
                        .font(.system(size: 14 * textScale))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        // The text view above it takes the clicks. `allowsHitTesting(false)` would
                        // redraw this text on every live-resize frame and stall each commit.
                        .accessibilityHidden(true)
                }
                NativeComposerInput(text: $draft.text, document: draftID, height: $inputHeight,
                                    focused: $isFocused, dragging: $isDragging, fontSize: 14 * textScale,
                                    focusRequest: focusRequest,
                                    agents: store.roster, canManage: store.phase.isLive,
                                    onSend: send, onFiles: draft.attachFiles, onImage: draft.append,
                                    onError: { draft.error = $0 },
                                    onCreate: { name in
                                        try await management.createMentionMember(name: name, store: store, catalog: app.catalog)
                                    },
                                    onEdit: { agent in
                                        management.present(.editMember(channelId: store.id, agentId: agent.id))
                                    }, snapshot: snapshot, failureFeedback: failureFeedback,
                                    dictation: dictation)
                    .frame(height: inputHeight)
            }
            HStack(spacing: 8) {
                AttachImagesButton { showPicker = true }
                ComposerAudienceView(text: draft.text, agents: store.roster,
                                     acknowledgesRequest: store.requestSequence != nil)
                if let request = store.request { inputNeeded(request) }
                Spacer(minLength: 0)
                if draft.isLoadingImages {
                    ProgressView().controlSize(.small).help("Reading images")
                }
                DictateButton(dictation: dictation) {
                    dictation.contextualStrings = dictationContext
                    dictation.toggle()
                }
                Button(action: send) {
                    Image(systemName: associatedAttempt?.canRetry == true ? "arrow.clockwise" : "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(canSend ? Color.accentColor : Color(nsColor: .quaternaryLabelColor), in: Circle())
                        .foregroundStyle(canSend ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(store.phase.isLive
                      ? (associatedAttempt?.canRetry == true ? "Send Again using the original message ID" : "Send message (Return)")
                      : "Reconnect before sending")
                .accessibilityLabel(associatedAttempt?.canRetry == true ? "Send Again" : "Send message")
            }
            .font(.system(size: 12))
            .frame(height: 28)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .overlay {
            if isDragging || contrast == .increased {
                shape
                    .strokeBorder(isDragging ? Color.accentColor : Color.primary.opacity(0.5),
                                  lineWidth: isDragging ? 2 : 1)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL, .image], isTargeted: $isDragging) { providers in
            providers.map { draft.attachProvider($0) }.contains(true)
        }
    }

    private func inputNeeded(_ request: ChannelMessage) -> some View {
        Button {
            requestPreview = false
            interaction.reveal(sequence: request.sequence)
        } label: {
            Label {
                Text("Input Needed").foregroundStyle(.primary)
            } icon: {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            }
            .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .help("Reveal the unanswered request")
        .onHover(perform: setRequestHover)
        .popover(isPresented: $requestPreview, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Input Needed").font(.headline)
                ScrollView {
                    TranscriptMarkdown(content: request.text, agents: store.roster,
                                       baseURL: store.api.baseURL)
                }
                    .frame(maxHeight: 180)
                if let error = store.historyError {
                    Label {
                        Text(error).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    }
                    .font(.caption)
                }
                Button(store.historyError == nil ? "Reveal Request" : "Retry Reveal") {
                    requestPreview = false
                    interaction.reveal(sequence: request.sequence)
                }
            }
            .padding(16)
            .frame(width: 320)
            .frame(maxHeight: 280)
            .onHover(perform: setRequestHover)
        }
        .accessibilityLabel("Input needed. Reveal the unanswered request.")
    }

    private func setRequestHover(_ hovering: Bool) {
        requestHoverTask?.cancel()
        requestHoverTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(hovering ? 550 : 250)) }
            catch { return }
            requestPreview = hovering
        }
    }

    private var connectionExplanation: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: store.phase == .deleted ? "trash" : "wifi.slash")
            Text(store.phase == .deleted
                 ? "This channel was deleted. \(draft.isSavedLocally ? "Your draft is saved locally." : "Copy your draft somewhere safe.")"
                 : "\(draft.isSavedLocally ? "Your draft is saved locally." : "This draft could not be saved locally.") Reconnect before sending so the audience is current.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if store.phase != .deleted {
                Button("Reconnect") { store.reconnect() }.buttonStyle(.link)
            } else if draft.hasContent {
                Button("Copy Draft") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft.text, forType: .string)
                }.buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func composerError(_ error: String, dismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                Text(error).foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
            }
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let dismiss {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .font(.caption)
    }

    private func send() {
        guard canSend, !sendsAfterDictation else { return }
        if dictation.isSessionActive {
            // Only finalized words are sent. Wait for the transcriber's last pass, then send.
            sendsAfterDictation = true
            Task {
                let finalized = await dictation.stop(.send)
                sendsAfterDictation = false
                if finalized { send() }
            }
            return
        }
        dictation.draftSent()
        let content = draft.text
        let images = draft.images.map(\.attachment)
        let revision = draft.revision
        let id = draft.sendAttemptID ?? UUID().uuidString
        draft.associateSend(id: id)
        let draftID = draftID
        if unrecordedFailure?.draft == draftID { unrecordedFailure = nil }
        submitting = draftID
        interaction.jumpToLatest()
        Task {
            do {
                _ = try await store.post(id: id, content: content, attachments: images)
                draft.clear(ifUnchanged: revision)
                interaction.jumpToLatest()
            } catch {
                // A failed attempt shows its error in the transcript beside Edit and Send Again.
                if store.sendAttempts.first(where: { $0.id == id })?.error == nil {
                    unrecordedFailure = (draftID, error.localizedDescription)
                }
            }
            if submitting == draftID { submitting = nil }
        }
    }

    private func restore(_ attempt: ChannelSendAttempt) {
        draft.restore(content: attempt.content, attachments: attempt.attachments, sendAttemptID: attempt.id)
        focusRequest = UUID()
    }

    private func reconcileDraft() {
        guard draft.sendAttemptID != nil else { return }
        if sentMessageArrived || associatedAttempt?.phase == .confirmed {
            draft.clear(ifUnchanged: draft.revision)
            if unrecordedFailure?.draft == draftID { unrecordedFailure = nil }
        }
    }

    /// Points the window's interaction and dictation at the draft being composed.
    private func adoptDraft() {
        registerDraft()
        reconcileDraft()
        dictation.draftRevision = { [draft] in draft.revision }
    }

    private func registerDraft() {
        interaction.hasDraft = draft.hasContent
        interaction.copyDraft = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(draft.text, forType: .string)
        }
    }
}
