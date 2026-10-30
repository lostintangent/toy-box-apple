import AppKit
import ChannelClient
import ChannelKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared editing surface for Quick Send and a single expanded inbox request.
struct AuxiliaryComposer: View {
    enum Style { case quickSend, reply }

    @Bindable var session: AuxiliaryComposerSession
    var style: Style = .reply
    var isPresented = true
    var presentationID = UUID()
    var onConfirmed: (AuxiliaryComposerSession.Confirmation) -> Void
    var onOpenChannel: () -> Void
    var onDismiss: () -> Void
    var onChooseChannel: (() -> Void)? = nil
    var onDraggingChanged: ((Bool) -> Void)? = nil
    var focusID: UUID? = nil
    var incomingContentNotice: String? = nil

    @Environment(\.channelTextScale) private var textScale
    @ViewState private var inputHeight: CGFloat = 84
    @ViewState private var dragging = false
    @ViewState private var showPicker = false
    @ViewState private var focusRequest = UUID()
    @ViewState private var dictation = ComposerDictation()
    @ViewState private var finalizing = false
    @ViewState private var noticeHeight: CGFloat = 0
    @ViewState private var imageHeight: CGFloat = 92

    private var draft: ComposerDraft { session.draft }
    private var store: ChannelStore { session.store }
    private var draftID: ObjectIdentifier { ObjectIdentifier(draft) }
    private var noticeRegionHeight: CGFloat { noticeHeight > 0 ? min(noticeHeight, 84) + 16 : 0 }
    private var canEdit: Bool { !session.isReadOnly && session.confirmation == nil }
    private var isConnecting: Bool { store.phase == .connecting }
    private var canSend: Bool {
        !finalizing && (session.canSend || (dictation.hasWords && !store.isSending && channelCanSend(
            isConnected: store.phase.isConnected, isSending: false, isSubmitting: false,
            hasContent: !session.requestChanged,
            isLoadingImages: draft.isLoadingImages, hasUnreadableImage: draft.hasUnreadableImage,
            textUTF16Count: draft.text.utf16.count
        )))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.confirmation != nil {
                Label(confirmationText,
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: style == .reply ? 84 : 144)
                    .onAppear {
                        guard let confirmation = session.takeConfirmationPresentation() else { return }
                        if isPresented, let window = NSApp.keyWindow {
                            NSAccessibility.post(element: window, notification: .announcementRequested,
                                                 userInfo: [.announcement: confirmationText,
                                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                        }
                        onConfirmed(confirmation)
                    }
            } else {
                ScrollView {
                    notices
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noticeHeight = $0 }
                }
                .frame(height: min(noticeHeight, 84))
                .padding(.vertical, noticeHeight > 0 ? 8 : 0)
                if !draft.images.isEmpty {
                    ComposerImageStrip(draft: draft).disabled(!canEdit)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { imageHeight = $0 }
                }
                editor
                controls.padding(.top, style == .quickSend ? 12 : 4)
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
        .onChange(of: focusID) { _, _ in
            if isPresented { focusRequest = UUID() }
        }
        .onChange(of: dragging) { _, value in onDraggingChanged?(value) }
        .onChange(of: draft.revision) { _, revision in
            registerDraft()
            dictation.draftChanged(to: revision)
        }
        .onChange(of: store.phase) { _, phase in
            if phase == .deleted {
                dictation.leaveDraft()
                showPicker = false
            }
        }
        .onDisappear { dictation.deactivate() }
    }

    private var editor: some View {
        @Bindable var draft = draft
        return ZStack(alignment: .topLeading) {
            if draft.text.isEmpty && !dictation.hasWords {
                Text(dictation.isListening ? "Listening…" : "Message this channel, or @mention an agent")
                    .font(.system(size: (style == .quickSend ? 16 : 14) * textScale))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .accessibilityHidden(true)
            }
            NativeComposerInput(
                text: $draft.text, document: draftID, height: $inputHeight, dragging: $dragging,
                fontSize: (style == .quickSend ? 16 : 14) * textScale, focusRequest: focusRequest,
                agents: store.roster, onSend: { send(opensChannel: false) },
                onFiles: draft.attachFiles, onImage: draft.append, onError: { draft.error = $0 },
                dictation: dictation, isEditable: canEdit,
                minimumHeight: style == .quickSend ? 100 : 84, maximumLineCount: style == .quickSend ? 10 : 3,
                startsAtEnd: true,
                onSendAndOpen: { send(opensChannel: true) }, onEscape: dismissOrStopDictation,
                onChooseChannel: onChooseChannel,
                onPrepareForExternalEdit: { session.prepareForExternalEdit = $0 }
            )
            .frame(height: style == .quickSend
                   ? min(inputHeight, max(100, 300 - noticeRegionHeight
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
            .disabled(!canEdit || store.phase == .deleted)
            if session.isSubmitting || finalizing || session.attempt?.phase == .sending {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
                    .accessibilityLabel("Sending")
            } else if session.isUnconfirmed {
                Button("Edit") { session.edit(); focusRequest = UUID() }.buttonStyle(.borderless)
                if isConnecting {
                    ComposerConnectingIndicator()
                } else {
                    Button("Send Again") { send(opensChannel: false) }.disabled(!canSend)
                        .help("Retry the original message with the same message ID")
                }
            } else if isConnecting {
                ComposerConnectingIndicator()
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
                .help(style == .reply ? "Reply \u{00b7} Return" : "Send \u{00b7} Return")
                .accessibilityLabel(style == .reply ? "Reply" : "Send message")
                .accessibilityHint(store.phase.sendUnavailableReason
                                   ?? (session.requestChanged ? session.requestChangeNotice : ""))
                .contextMenu {
                    Button("Send and Open Channel") { send(opensChannel: true) }
                        .keyboardShortcut(.return, modifiers: .command).disabled(!canSend)
                }
            }
        }
        .font(.system(size: 12))
        .frame(height: 32)
    }

    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let incomingContentNotice { Text(incomingContentNotice) }
            if session.requestChanged {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.requestChangeNotice)
                    Spacer(minLength: 0)
                    Button("Open Channel", action: onOpenChannel).buttonStyle(.link)
                }
            } else if let notice = session.deliveryNotice {
                Text(notice).foregroundStyle(.primary)
            }
            if session.editedUnconfirmedMessage {
                Text("Sending edited text creates a new message. The earlier message may already have arrived.")
            }
            if let error = draft.error {
                HStack(alignment: .firstTextBaseline) {
                    Text(error).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Button("Dismiss", systemImage: "xmark") { draft.error = nil }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            if let error = store.attemptPersistenceError { Text(error).foregroundStyle(.primary) }
            if let error = session.error, session.deliveryNotice == nil { Text(error).foregroundStyle(.primary) }
            if let notice = dictation.notice { Text(notice.text) }
            if draft.text.utf16.count > 12_000 { Text("Messages are limited to 12,000 characters.") }
            if store.phase.isUnavailable {
                HStack(alignment: .firstTextBaseline) {
                    Text(connectionText)
                    Spacer(minLength: 0)
                    if store.phase == .deleted, let onChooseChannel {
                        Button("Choose Channel", action: onChooseChannel).buttonStyle(.link)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private var connectionText: String {
        if store.phase == .deleted {
            return draft.isSavedLocally ? "This channel is no longer available. Your draft is saved."
                : "This channel is no longer available. This draft could not be saved. Copy it somewhere safe."
        }
        return draft.isSavedLocally ? "Offline. Your draft stays on this Mac."
            : "Offline. This draft could not be saved. Copy it somewhere safe."
    }

    private var confirmationText: String {
        style == .reply ? "Reply sent" : "Sent to \(store.details?.name ?? "channel")"
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
