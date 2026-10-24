import AppKit
import ChannelClient
import ChannelKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared editing surface for Quick Ask and a single expanded inbox request.
struct AuxiliaryComposer: View {
    enum Style { case quickAsk, reply }

    @Bindable var session: AuxiliaryComposerSession
    var style: Style = .reply
    var isPresented = true
    var presentationID = UUID()
    var onConfirmed: (AuxiliaryComposerSession.Confirmation) -> Void
    var onOpenChannel: () -> Void
    var onDismiss: () -> Void
    var onChooseChannel: (() -> Void)? = nil
    var onDraggingChanged: ((Bool) -> Void)? = nil

    @Environment(\.channelTextScale) private var textScale
    @ViewState private var inputHeight: CGFloat = 84
    @ViewState private var focused = false
    @ViewState private var dragging = false
    @ViewState private var showPicker = false
    @ViewState private var focusRequest = UUID()
    @ViewState private var dictation = ComposerDictation()
    @ViewState private var finalizing = false
    @ViewState private var connectGrace = ConnectGrace()
    @ViewState private var noticeHeight: CGFloat = 0
    @ViewState private var imageHeight: CGFloat = 92

    private var draft: ComposerDraft { session.draft }
    private var store: ChannelStore { session.store }
    private var draftID: ObjectIdentifier { ObjectIdentifier(draft) }
    private var canEdit: Bool { !session.isReadOnly && session.confirmation == nil }
    private var canSend: Bool {
        !finalizing && (session.canSend || (dictation.hasWords && !store.isSending && store.phase.isLive
            && !session.requestChanged && !draft.isLoadingImages && !draft.hasUnreadableImage
            && draft.text.utf16.count <= 12_000))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let confirmation = session.confirmation {
                Label(style == .reply ? "Reply sent" : "Sent to \(store.state?.channel.name ?? "channel")",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: style == .reply ? 84 : 144)
                    .onAppear {
                        if let window = NSApp.keyWindow {
                            NSAccessibility.post(element: window, notification: .announcementRequested,
                                                 userInfo: [.announcement: style == .reply ? "Reply sent" : "Message sent",
                                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                        }
                        onConfirmed(confirmation)
                    }
            } else {
                if !draft.images.isEmpty {
                    ComposerImageStrip(draft: draft).disabled(!canEdit)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { imageHeight = $0 }
                }
                editor
                ScrollView {
                    notices
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noticeHeight = $0 }
                }
                .frame(height: min(noticeHeight, 100))
                controls.padding(.top, style == .quickAsk ? 12 : 4)
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): draft.attachFiles(urls)
            case .failure(let error): draft.error = "Images could not be attached: \(error.localizedDescription)"
            }
        }
        .onDrop(of: [UTType.fileURL, .image], isTargeted: $dragging) { providers in
            guard canEdit else { return false }
            return providers.map { draft.attachProvider($0) }.contains(true)
        }
        .onAppear { updatePresentation() }
        .onChange(of: presentationID) { _, _ in updatePresentation() }
        .onChange(of: isPresented) { _, _ in updatePresentation() }
        .onChange(of: dragging) { _, value in onDraggingChanged?(value) }
        .onChange(of: draft.revision) { _, revision in
            registerDraft()
            dictation.draftChanged(to: revision)
        }
        .onDisappear { dictation.deactivate() }
        .task(id: store.phase) { await connectGrace.watch(store.phase, for: draftID) }
    }

    private var editor: some View {
        @Bindable var draft = draft
        return ZStack(alignment: .topLeading) {
            if draft.text.isEmpty && !dictation.hasWords {
                Text(dictation.isListening ? "Listening…" : "Message this channel, or @mention an agent")
                    .font(.system(size: (style == .quickAsk ? 16 : 14) * textScale))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .accessibilityHidden(true)
            }
            NativeComposerInput(
                text: $draft.text, document: draftID, height: $inputHeight, focused: $focused, dragging: $dragging,
                fontSize: (style == .quickAsk ? 16 : 14) * textScale, focusRequest: focusRequest,
                agents: store.roster, canManage: false, onSend: { send(opensChannel: false) },
                onFiles: draft.attachFiles, onImage: draft.append, onError: { draft.error = $0 },
                onCreate: { _ in throw AuxiliaryEditingError.managementUnavailable }, onEdit: { _ in },
                dictation: dictation, allowsAgentManagement: false, isEditable: canEdit,
                minimumHeight: style == .quickAsk ? 100 : 84, maximumLineCount: style == .quickAsk ? 10 : 3,
                onSendAndOpen: { send(opensChannel: true) }, onEscape: dismissOrStopDictation,
                onChooseChannel: onChooseChannel
            )
            .frame(height: style == .quickAsk
                   ? min(inputHeight, max(100, 300 - min(noticeHeight, 100)
                                          - (draft.images.isEmpty ? 0 : imageHeight)))
                   : 60 * textScale + 24)
        }
        .background(style == .reply ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            AttachImagesButton { showPicker = true }.disabled(!canEdit)
            ComposerAudienceView(text: draft.text, agents: store.roster,
                                 acknowledgesRequest: store.requestSequence != nil, hasBackground: false)
            Spacer(minLength: 0)
            if draft.isLoadingImages { ProgressView().controlSize(.small) }
            DictateButton(dictation: dictation) {
                registerDraft()
                dictation.toggle()
            }
            .disabled(!canEdit)
            if session.isSubmitting || finalizing || session.attempt?.phase == .sending {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
                    .accessibilityLabel("Sending")
            } else if session.isUnconfirmed {
                Button("Edit") { session.edit(); focusRequest = UUID() }.buttonStyle(.borderless)
                Button("Send Again") { send(opensChannel: false) }.disabled(!canSend)
                    .help("Retry the original message with the same message ID")
            } else {
                Button { send(opensChannel: false) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(canSend ? Color.accentColor : Color(nsColor: .quaternaryLabelColor), in: Circle())
                        .foregroundStyle(canSend ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(style == .reply ? "Reply (Return)" : "Send (Return)")
                .accessibilityLabel(style == .reply ? "Reply" : "Send message")
                .contextMenu {
                    Button("Send and Open Channel") { send(opensChannel: true) }.disabled(!canSend)
                }
            }
        }
        .font(.system(size: 12))
        .frame(height: 32)
    }

    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.requestChanged {
                HStack(alignment: .firstTextBaseline) {
                    Text("This request was answered or replaced. Your draft is still here.")
                    Spacer(minLength: 0)
                    Button("Open Channel", action: onOpenChannel).buttonStyle(.link)
                }
            } else if let notice = session.deliveryNotice {
                Text(notice).foregroundStyle(.primary)
            }
            if session.editedUnconfirmedMessage {
                Text("Sending edited text creates a new message. The earlier message may already have arrived.")
            }
            if let error = draft.error { Text(error).foregroundStyle(.primary) }
            if let error = store.attemptPersistenceError { Text(error).foregroundStyle(.primary) }
            if let error = session.error, session.deliveryNotice == nil { Text(error).foregroundStyle(.primary) }
            if let notice = dictation.notice { Text(notice.text) }
            if draft.text.utf16.count > 12_000 { Text("Messages are limited to 12,000 characters.") }
            if connectGrace.explains(store.phase, for: draftID) {
                HStack(alignment: .firstTextBaseline) {
                    Text(connectionText)
                    Spacer(minLength: 0)
                    if store.phase == .deleted, let onChooseChannel {
                        Button("Choose Channel", action: onChooseChannel).buttonStyle(.link)
                    } else if store.phase != .deleted {
                        Button("Retry") { store.reconnect() }.buttonStyle(.link)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private var connectionText: String {
        if store.phase == .deleted { return "This channel was deleted. Your draft stays on this Mac." }
        if ConnectGrace.isConnecting(store.phase) { return "Connecting…" }
        return draft.isSavedLocally ? "Offline. Your draft stays on this Mac."
            : "Offline. This draft could not be saved. Copy it somewhere safe."
    }

    private func registerDraft() {
        dictation.draftRevision = { [weak draft] in draft?.revision }
        dictation.contextualStrings = store.roster.map { "@\(agentHandleFromName($0.name))" }
    }

    private func updatePresentation() {
        if isPresented {
            session.beginPresentation()
            registerDraft()
            dictation.activate()
            focusRequest = UUID()
        } else {
            dictation.deactivate()
            showPicker = false
        }
    }

    private func send(opensChannel: Bool) {
        guard canSend else { return }
        finalizing = true
        Task {
            let finalized = if dictation.isSessionActive { await dictation.stop(.send) } else { true }
            finalizing = false
            guard finalized else { return }
            dictation.draftSent()
            await session.send(opensChannel: opensChannel)
        }
    }

    private func dismissOrStopDictation() {
        if dictation.phase != .idle { dictation.commitNow() }
        else { onDismiss() }
    }
}

private enum AuxiliaryEditingError: LocalizedError {
    case managementUnavailable
    var errorDescription: String? { "Open the channel to manage agents." }
}
