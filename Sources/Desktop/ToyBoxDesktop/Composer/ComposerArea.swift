import AppKit
import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UniformTypeIdentifiers

struct ComposerArea: View {
    let store: ChannelStore
    @Environment(AppModel.self) private var app
    @Environment(\.windowSnapshot) private var snapshot
    @ViewState private var snapshotDraft = ComposerDraft()

    /// One composer serves the window. A switch hands it the next channel's draft, so its text view
    /// is kept rather than rebuilt.
    var body: some View {
        ChannelComposer(session: app.composerSession(
            for: store, draft: snapshot == nil
                ? .shared(serverURL: store.api.baseURL, channelID: store.id) : snapshotDraft
        ))
    }
}

extension ChannelConnectionPhase {
    /// Why Send is off once the channel is unavailable, for its help and accessibility hint.
    /// A quiet connect says nothing, since Send is a spinner then.
    var sendUnavailableReason: String? {
        switch self {
        case .failed: "The channel isn't connected"
        case .deleted: "This channel was deleted"
        case .connecting, .connected: nil
        }
    }
}

/// Stands in for Send, in its frame, while the channel connects quietly.
struct ComposerConnectingIndicator: View {
    var size: CGFloat = 28

    var body: some View {
        ProgressView().controlSize(.small)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel("Connecting")
    }
}

/// Opens the image picker. Like Dictate, the whole 28pt circle lights, takes clicks and is its
/// accessibility frame.
struct AttachImagesButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "photo.badge.plus")
                .frame(width: 28, height: 28)
                .contentShape([.interaction, .accessibility], Circle())
        }
        .buttonStyle(HoverFillButtonStyle(shape: Circle()))
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
                    ComposerImageTile(draft: draft, image: image)
                }
            }
            .padding(12)
        }
        // `.hidden` still shows a legacy scroller for mouse users, which would grow the strip 17pt.
        .scrollIndicators(.never)
    }
}

private struct ComposerImageTile: View {
    let draft: ComposerDraft
    let image: ComposerImage
    @ViewState private var loaded: (image: ComposerImage, bitmap: CGImage?)?

    var body: some View {
        let retained = loaded?.image == image ? loaded?.bitmap : nil
        let thumbnail = draft.thumbnail(for: image, retaining: retained)
        let unavailable = loaded?.image == image && thumbnail == nil
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                    } else if !unavailable {
                        RoundedRectangle(cornerRadius: 7).fill(.quaternary)
                            .accessibilityLabel("Loading \(image.name)")
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
        .help(unavailable ? "\(image.name) must be reattached" : image.name)
        .task(id: image) {
            let decoded = await draft.loadThumbnail(for: image)
            guard !Task.isCancelled else { return }
            loaded = (image, decoded)
        }
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
    @Bindable var session: ChannelComposerSession
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ManagementPresenter.self) private var management
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.windowSnapshot) private var snapshot
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewState private var inputHeight: CGFloat = 44
    @ViewState private var isDragging = false
    @ViewState private var showPicker = false
    @ViewState private var focusRequest = UUID()
    @ViewState private var caretRequest: NativeComposerInput.CaretRequest?
    @ViewState private var requestPreview = false
    @ViewState private var requestHoverTask: Task<Void, Never>?
    @ViewState private var dictation = ComposerDictation()

    /// The draft's identity. There's one draft per server and channel.
    private var store: ChannelStore { session.store }
    private var draft: ComposerDraft { session.draft }
    private var draftID: ObjectIdentifier { ObjectIdentifier(draft) }

    private var explainsDeletion: Bool { store.phase == .deleted }

    private var canSend: Bool {
        session.canSend(hasAdditionalContent: dictation.hasWords)
    }

    private var placeholder: String {
        if store.requestSequence != nil {
            return "Reply to Lead, or @mention an agent"
        }
        return "Message the team, or @mention an agent"
    }

    private var hasNotices: Bool {
        draft.error != nil || explainsDeletion || draft.isOverLimit || dictation.notice != nil
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
            guard let reply = interaction.replyRequest else { return }
            dictation.commitNow()
            let before = draft.text.utf16.count
            session.reply(to: reply.agent)
            let inserted = draft.text.utf16.count - before
            if inserted > 0 { caretRequest = .init(id: UUID(), location: inserted) }
            focusRequest = UUID()
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
            adoptDraft()
        }
        .onChange(of: draft.revision) { _, revision in
            registerDraft()
            dictation.draftChanged(to: revision)
        }
        .task(id: snapshot?.requestedState) {
            switch snapshot?.requestedState {
            case "composer-draft":
                draft.text = "@ada Here's the latest screenshot.\nThe draft stays with this channel.\nReady for your review."
                focusRequest = UUID()
            case "composer-mentions":
                draft.text = "@"
                focusRequest = UUID()
            case "composer-notices":
                draft.text = "Here's the revised entrance layout."
                draft.error = "Library sketch.heic cannot be decoded as an image. Attach a readable image file."
                snapshot?.markStateReady("composer-notices")
            case "hover-all":
                // Every control in `HoverFillButtonStyle` lights itself for this state.
                snapshot?.markStateReady("hover-all")
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
            if explainsDeletion {
                deletionNotice
            }
            if draft.isOverLimit {
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
                NativeComposerInput(text: Bindable(draft).text, document: draftID, height: $inputHeight,
                                    dragging: $isDragging, fontSize: 14 * textScale,
                                    focusRequest: focusRequest, caretRequest: caretRequest,
                                    agents: store.roster,
                                    onSend: send, onFiles: draft.attachFiles, onImage: draft.append,
                                    onError: { draft.error = $0 },
                                    agentManagement: store.phase.isConnected ? .enabled(create: { name in
                                        try await management.createMentionMember(name: name, store: store)
                                    }, edit: { agent in
                                        if let target = store.target { management.present(.editMember(target, agentId: agent.id)) }
                                    }) : .disabled, snapshot: snapshot,
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
                if store.phase == .connecting {
                    ComposerConnectingIndicator()
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(canSend ? Color.accentColor : Color(nsColor: .quaternaryLabelColor), in: Circle())
                            .foregroundStyle(canSend ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help(store.phase.sendUnavailableReason ?? "Send message (Return)")
                    .accessibilityLabel("Send message")
                }
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
            .modifier(ComposerCapsuleLabel())
        }
        .buttonStyle(HoverFillButtonStyle(shape: Capsule()))
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

    private var deletionNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "trash")
            Text("This channel was deleted. \(draft.isSavedLocally ? "Your draft is saved locally." : "Copy your draft somewhere safe.")")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if draft.hasContent {
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
        guard canSend, !dictation.holdsSend else { return }
        let session = session
        Task.immediate {
            // Only finalized words are sent, so Send waits for the transcriber's last pass.
            guard await dictation.stop(.send), canSend else { return }
            interaction.jumpToLatest()
            if await session.send() != nil { interaction.jumpToLatest() }
        }
    }

    /// Points the window's interaction and dictation at the draft being composed.
    private func adoptDraft() {
        registerDraft()
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
