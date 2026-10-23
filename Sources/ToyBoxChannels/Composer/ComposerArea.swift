import AppKit
import ChannelClient
import ChannelKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerArea: View {
    let store: ChannelStore
    @Environment(\.windowSnapshot) private var snapshot
    @ViewState private var snapshotDraft = ComposerDraft()

    var body: some View {
        ChannelComposer(store: store, draft: snapshot == nil
                        ? .shared(serverURL: store.api.baseURL, channelID: store.id) : snapshotDraft)
            .id("\(store.api.baseURL.absoluteString):\(store.id)")
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
    @ViewState private var isSubmitting = false
    @ViewState private var pendingEdit: ChannelSendAttempt?
    @ViewState private var showAppendConfirmation = false
    @ViewState private var submissionError: String?
    @ViewState private var dictation = ComposerDictation()
    @ViewState private var sendsAfterDictation = false

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

    private var placeholder: String {
        if store.state?.channel.requestSequence != nil {
            return "Reply to Lead, or @mention an agent"
        }
        return "Message the team, or @mention an agent"
    }

    private var isOverLimit: Bool { draft.text.utf16.count > 12_000 }
    private var hasNotices: Bool {
        draft.error != nil || store.attemptPersistenceError != nil || submissionError != nil
            || !store.phase.isLive || isOverLimit || dictation.notice != nil
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
            registerDraft()
            reconcileDraft()
            dictation.draftRevision = { [draft] in draft.revision }
            dictation.activate()
        }
        .onChange(of: draft.revision) { _, revision in
            registerDraft()
            dictation.draftChanged(to: revision)
        }
        .onChange(of: store.state?.revision) { _, _ in reconcileDraft() }
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
        case "composer-dictation-listening", "composer-dictation-listening-empty", "composer-dictation-download",
             "composer-dictation-recording", "composer-dictation-unsent":
            dictation.contextualStrings = dictationContext
            dictation.toggle()
            let deadline = ContinuousClock.now + .seconds(recording ? 20 : 5)
            while ContinuousClock.now < deadline {
                let ready = switch name {
                case "composer-dictation-listening": dictation.isListening && dictation.hasWords && !draft.text.isEmpty
                case "composer-dictation-recording", "composer-dictation-unsent":
                    dictation.hasTentativeWords && !draft.text.isEmpty
                case "composer-dictation-download": dictation.notice != nil
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
        (store.state?.agents ?? []).filter { $0.deleted != true }.map(\.name) + ["Lead", "Everyone"]
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
            if !store.phase.isLive {
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

    private var hairline: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.horizontal, 12)
            .accessibilityHidden(true)
    }

    private var input: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(spacing: 0) {
            if hasNotices {
                notices
                hairline
            }
            if let state = store.state, ComposerTray.isVisible(for: state) {
                ComposerTray(state: state, api: store.api)
                hairline
            }
            if !draft.images.isEmpty { imageStrip }
            ZStack(alignment: .topLeading) {
                if draft.text.isEmpty && !dictation.hasWords {
                    Text(dictation.isListening ? "Listening…" : placeholder)
                        .font(.system(size: 14 * textScale))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                NativeComposerInput(text: $draft.text, height: $inputHeight, focused: $isFocused,
                                    dragging: $isDragging, fontSize: 14 * textScale,
                                    focusRequest: focusRequest,
                                    agents: store.state?.agents ?? [], canManage: store.phase.isLive,
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
                if let state = store.state { audience(state) }
                if let request = store.state?.request { inputNeeded(request) }
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

    private var imageStrip: some View {
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
        .scrollIndicators(.hidden)
    }

    private func audience(_ state: ChannelState) -> some View {
        let recipients = resolveChannelAudience(content: draft.text, sender: .user, lead: state.lead,
                                                members: state.members,
                                                acknowledgedRequest: state.channel.requestSequence != nil)
        let names = recipients.map(\.name).joined(separator: ", ")
        let label = recipients.isEmpty ? "No one will be notified"
            : "To \(channelAudienceLabel(recipients, reachableCount: state.agents.count))"
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                if recipients.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    ForEach(recipients.prefix(3)) { agent in AgentAvatarView(agent: agent, size: 16) }
                }
                Text(label).lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 4) {
                if let first = recipients.first {
                    AgentAvatarView(agent: first, size: 16)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(recipients.isEmpty ? "No recipients" : "\(recipients.count)")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(recipients.isEmpty ? Color.orange.opacity(0.1) : Color.secondary.opacity(0.08), in: Capsule())
        .foregroundStyle(recipients.isEmpty ? Color.primary : .secondary)
        .help(recipients.isEmpty ? label : "Notifies \(names)")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(recipients.isEmpty ? label : "To \(names)")
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
                    TranscriptMarkdown(content: request.text, agents: store.state?.agents ?? [],
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
        submissionError = nil
        isSubmitting = true
        interaction.jumpToLatest()
        Task {
            do {
                _ = try await store.post(id: id, content: content, attachments: images)
                draft.clear(ifUnchanged: revision)
                interaction.jumpToLatest()
            } catch {
                // A failed attempt shows its error in the transcript beside Edit and Send Again.
                if store.sendAttempts.first(where: { $0.id == id })?.error == nil {
                    submissionError = error.localizedDescription
                }
            }
            isSubmitting = false
        }
    }

    private func restore(_ attempt: ChannelSendAttempt) {
        draft.restore(content: attempt.content, attachments: attempt.attachments, sendAttemptID: attempt.id)
        focusRequest = UUID()
    }

    private func reconcileDraft() {
        guard let id = draft.sendAttemptID else { return }
        if store.state?.messages.contains(where: { $0.id == id }) == true || associatedAttempt?.phase == .confirmed {
            draft.clear(ifUnchanged: draft.revision)
            submissionError = nil
        }
    }

    private func registerDraft() {
        interaction.hasDraft = draft.hasContent
        interaction.copyDraft = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(draft.text, forType: .string)
        }
    }
}
