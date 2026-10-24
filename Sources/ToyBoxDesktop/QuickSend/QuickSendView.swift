import AppKit
import ChannelClient
import ChannelKit
import SwiftUI
import UniformTypeIdentifiers

struct QuickSendView: View {
    var lastUsedChannel: () -> String? = { nil }
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openSettings) private var openSettings
    @AppStorage("textScale") private var textScale = 1.0
    @ViewState private var history: QuickSendTargetHistory?
    @ViewState private var incoming: QuickSendPrefillInbox?
    @ViewState private var sessions: [String: AuxiliaryComposerSession] = [:]
    @ViewState private var replySession: AuxiliaryComposerSession?
    @ViewState private var heldStore: ChannelStore?
    @ViewState private var showsChooser = false
    @ViewState private var focusID = UUID()
    @ViewState private var confirmationDismissal: Task<Void, Never>?
    @ViewState private var isDragging = false
    @ViewState private var catalogConnectingLong = false

    private var channels: [Channel] { model.catalog?.channels ?? [] }
    private var selectedID: String? { model.quickSend.replyTarget?.channelID ?? history?.selectedID }
    private var session: AuxiliaryComposerSession? {
        model.quickSend.replyTarget == nil ? selectedID.flatMap { sessions[$0] } : replySession
    }
    private var replyItem: MenuBarStatus.Item? {
        guard let target = model.quickSend.replyTarget else { return nil }
        return model.menuBarStatus.waiting.first { $0.id == target.channelID }
    }
    private var showsHeader: Bool { session != nil || !channels.isEmpty }
    private var channelName: String {
        guard let selectedID else { return "Choose Channel" }
        return channels.first { $0.id == selectedID }?.name ?? session?.store.details?.name
            ?? history?.name(for: selectedID) ?? "Saved Channel"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader { header }
            if let session {
                AuxiliaryComposer(
                    session: session, style: .quickSend, isPresented: model.quickSend.isPresented,
                    presentationID: model.quickSend.presentationID, onConfirmed: { confirmed($0, session: session) },
                    onOpenChannel: { open(session) }, onDismiss: model.quickSend.dismiss,
                    onChooseChannel: { showsChooser = true }, onDraggingChanged: { isDragging = $0 },
                    focusID: focusID, incomingContentNotice: requestContextNotice ?? incomingContentNotice
                )
                .id(ObjectIdentifier(session))
            } else {
                emptyState.frame(maxWidth: .infinity, minHeight: showsHeader ? 144 : 188, alignment: .topLeading)
            }
            if let error = history?.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if session == nil, let error = incoming?.draft.error {
                ScrollView {
                    Text(error).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxHeight: 84)
            }
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 560)
        .glassEffect(.regular, in: shape)
        .overlay {
            if contrast == .increased || isDragging {
                shape.strokeBorder(isDragging ? Color.accentColor : Color.primary.opacity(0.5),
                                   lineWidth: isDragging ? 2 : 1).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL, .image], isTargeted: $isDragging) { providers in
            guard let session, !session.isReadOnly, session.confirmation == nil else { return false }
            return providers.map { session.draft.attachProvider($0) }.contains(true)
        }
        .environment(\.channelTextScale, textScale)
        .onChange(of: model.quickSend.isPresented, initial: true) { _, presented in
            if presented { beginPresentation() }
            else { endPresentation() }
        }
        .onChange(of: model.quickSend.presentationID) { _, _ in
            focusID = UUID()
            chooseInitialTarget()
            receivePendingPrefill()
        }
        .onChange(of: model.quickSend.replyTarget) { _, target in
            if target != nil { installReplySession(); holdSelectedStore() }
        }
        .onChange(of: replyItem) { _, _ in
            if model.quickSend.replyTarget != nil { installReplySession() }
        }
        .onChange(of: model.quickSend.pendingPrefill?.id) { _, _ in receivePendingPrefill() }
        .onChange(of: model.catalog?.hasLoaded) { _, loaded in
            if loaded == true, model.quickSend.isPresented,
               selectedID == nil || model.quickSend.replyTarget != nil { chooseInitialTarget() }
        }
        .onChange(of: selectedID) { _, _ in holdSelectedStore(); applyIncoming() }
        .onChange(of: session.map(ObjectIdentifier.init)) { _, _ in holdSelectedStore() }
        .onChange(of: session?.draft.revision) { _, _ in trackDraft() }
        .onChange(of: session?.isReadOnly) { _, _ in applyIncoming() }
        .onChange(of: session?.confirmation?.id) { _, _ in applyIncoming() }
        .onChange(of: incoming?.draft.isLoadingImages) { _, _ in applyIncoming() }
        .onChange(of: incoming?.draft.revision) { _, _ in applyIncoming() }
        .onChange(of: model.serverURL) { _, _ in
            confirmationDismissal?.cancel()
            for session in sessions.values { session.cancelOpenOnConfirmation() }
            model.quickSend.dismiss()
            endPresentation()
            sessions = [:]
            replySession = nil
            history = nil
            incoming = nil
        }
        .onDisappear { endPresentation() }
        .task(id: model.catalog?.hasLoaded) {
            catalogConnectingLong = false
            guard model.catalog?.hasLoaded == false else { return }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            catalogConnectingLong = true
        }
    }

    private var requestContextNotice: String? {
        guard let target = model.quickSend.replyTarget, session?.requestChanged == false,
              let item = replyItem, item.sequence == target.sequence else { return nil }
        let title = item.agent.map { "Reply to \($0.name)" } ?? "Reply to request"
        return item.quote.map { "\(title): \($0)" } ?? title
    }

    private var incomingContentNotice: String? {
        guard incoming?.hasPendingContent == true else { return nil }
        if let error = incoming?.draft.error { return error }
        if incoming?.draft.isSavedLocally == false {
            return "Shared content could not be saved. Keep Quick Send open and copy it somewhere safe."
        }
        if session?.isSubmitting == true {
            return "Shared content is saved and will be added after this send."
        }
        if session?.isReadOnly == true {
            return "Shared content is saved. Choose another channel or Edit this message to add it."
        }
        if session?.store.phase == .deleted {
            return "Shared content is saved. Choose another channel to add it."
        }
        return incoming?.draft.isLoadingImages == true ? "Adding shared images..." : nil
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.api == nil {
                Text("Connect to Toy Box").font(.system(size: 15, weight: .semibold))
                Text("Set a server in Settings to send a message.").foregroundStyle(.secondary)
                Button("Open Settings") {
                    model.quickSend.dismiss()
                    NSApplication.shared.activate()
                    openSettings()
                }
            } else if let target = model.quickSend.replyTarget {
                let unavailable = model.catalog?.error != nil || replyItem?.quote != nil
                Text(unavailable ? "Request preview unavailable" : "Loading request...")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.catalog?.error ?? (unavailable
                    ? "The requester is no longer available. Open the channel to review this request."
                    : "The original request is being checked before you reply."))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Retry") { model.retryMenuBarRequest(channelID: target.channelID) }
                    Button("Open Channel") {
                        model.quickSend.dismiss()
                        model.activate(channelID: target.channelID, sequence: target.sequence)
                    }
                }
            } else if model.catalog?.hasLoaded == true, channels.isEmpty {
                Text("No channels yet").font(.system(size: 15, weight: .semibold))
                Text("Open Toy Box to create one.").foregroundStyle(.secondary)
                Button("Open Toy Box") {
                    model.quickSend.dismiss()
                    model.activate(channelID: nil)
                }
            } else if let error = model.catalog?.error {
                Text("Offline.").font(.system(size: 15, weight: .semibold))
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Retry") { Task { await model.catalog?.refresh() } }
            } else if model.catalog?.hasLoaded == true {
                Text("Choose a channel to start a message.").foregroundStyle(.secondary)
            } else if catalogConnectingLong {
                Text("Connecting…").foregroundStyle(.secondary)
                Button("Retry") { Task { await model.catalog?.refresh() } }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { showsChooser.toggle() } label: {
                HStack(spacing: 6) {
                    Text(channelName).fontWeight(.medium).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("l", modifiers: .command)
            .disabled(session?.isSubmitting == true || session?.confirmation != nil)
            .accessibilityLabel("Channel, \(channelName)")
            .popover(isPresented: $showsChooser, arrowEdge: .bottom) {
                QuickSendChannelChooser(channels: history?.choices(channels: channels, query: "") ?? channels,
                                       history: history, selectedID: selectedID) { channel in
                    select(channel)
                    showsChooser = false
                }
            }
            Spacer(minLength: 0)
            Button {
                if let session { open(session) }
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(session == nil)
            .help("Open Channel")
            .accessibilityLabel("Open Channel")
        }
        .frame(height: 32)
        .onChange(of: showsChooser) { _, shown in
            if !shown { focusID = UUID() }
        }
    }

    private func beginPresentation() {
        confirmationDismissal?.cancel()
        if let api = model.api {
            if history == nil { history = .init(serverURL: api.baseURL) }
            if incoming == nil { incoming = .init(serverURL: api.baseURL) }
        }
        chooseInitialTarget()
        holdSelectedStore()
        receivePendingPrefill()
        applyIncoming()
        focusID = UUID()
    }

    private func receivePendingPrefill() {
        guard let api = model.api, let prefill = model.quickSend.pendingPrefill else { return }
        confirmationDismissal?.cancel()
        session?.cancelOpenOnConfirmation()
        if incoming?.serverURL != api.baseURL { incoming = .init(serverURL: api.baseURL) }
        incoming?.receive(prefill)
        model.quickSend.consumePrefill(id: prefill.id)
        applyIncoming()
    }

    private func applyIncoming() {
        guard model.quickSend.replyTarget == nil, let session, model.api?.baseURL == session.store.api.baseURL,
              model.catalog?.hasLoaded != true || channels.contains(where: { $0.id == session.store.id }),
              incoming?.apply(to: session) == true else { return }
        trackDraft()
        focusID = UUID()
    }

    private func chooseInitialTarget() {
        if model.quickSend.replyTarget != nil {
            showsChooser = false
            installReplySession()
            return
        }
        guard let api = model.api else { showsChooser = false; return }
        history?.restoreTarget(channels: channels, lastUsedID: model.activeChannelID ?? lastUsedChannel(),
                               catalogLoaded: model.catalog?.hasLoaded == true) {
            ComposerDraft.shared(serverURL: api.baseURL, channelID: $0, scope: .quickSend).hasContent
        }
        if let selectedID {
            installSession(channelID: selectedID)
        } else {
            showsChooser = model.catalog?.hasLoaded == true && !channels.isEmpty
        }
    }

    private func select(_ channel: Channel) {
        confirmationDismissal?.cancel()
        model.quickSend.leaveReply()
        history?.choose(channel)
        installSession(channelID: channel.id)
        applyIncoming()
        trackDraft()
        holdSelectedStore()
    }

    private func installReplySession() {
        guard let target = model.quickSend.replyTarget, target.serverURL == model.serverURL,
              let catalog = model.catalog else { return }
        let requester = replyItem.flatMap { $0.sequence == target.sequence ? $0.agent : nil }
        if replySession?.store.id != target.channelID || replySession?.requestSequence != target.sequence {
            let draft = ComposerDraft.shared(serverURL: catalog.api.baseURL, channelID: target.channelID,
                                             scope: .inboxReply(sequence: target.sequence))
            let knownChanged = catalog.hasLoaded
                && channels.first(where: { $0.id == target.channelID })?.requestSequence != target.sequence
            guard requester != nil || !draft.isNew || draft.hasContent || knownChanged else {
                replySession = nil
                return
            }
            replySession = AuxiliaryComposerSession(store: catalog.channel(id: target.channelID),
                scope: .inboxReply(sequence: target.sequence), requester: requester, draft: draft)
        } else if let requester {
            replySession?.seedRequesterIfNew(requester)
        }
        if catalog.hasLoaded {
            let current = channels.first { $0.id == target.channelID }?.requestSequence
            if current != target.sequence { replySession?.invalidateRequest(replacementSequence: current) }
        }
    }

    private func installSession(channelID: String) {
        guard sessions[channelID] == nil, let catalog = model.catalog else { return }
        sessions[channelID] = AuxiliaryComposerSession(store: catalog.channel(id: channelID), scope: .quickSend)
    }

    private func holdSelectedStore() {
        let next = model.quickSend.isPresented ? session?.store : nil
        guard heldStore !== next else { return }
        if let heldStore { model.release(heldStore) }
        heldStore = next
        if let next { model.acquire(next) }
    }

    private func trackDraft() {
        guard model.quickSend.replyTarget == nil, let selectedID, let session else { return }
        history?.trackDraft(channelID: selectedID, name: session.store.details?.name,
                            hasContent: session.draft.hasContent || session.draft.sendAttemptID != nil)
    }

    private func endPresentation() {
        confirmationDismissal?.cancel()
        showsChooser = false
        trackDraft()
        if let heldStore { model.release(heldStore) }
        heldStore = nil
    }

    private func open(_ session: AuxiliaryComposerSession, sequence: Int? = nil) {
        guard model.api?.baseURL == session.store.api.baseURL else { return }
        model.quickSend.dismiss()
        model.activate(channelID: session.store.id, sequence: sequence)
    }

    private func confirmed(_ confirmation: AuxiliaryComposerSession.Confirmation,
                           session: AuxiliaryComposerSession) {
        guard model.api?.baseURL == session.store.api.baseURL else { return }
        trackDraft()
        guard model.quickSend.isPresented, self.session === session else { return }
        if confirmation.opensChannel { open(session, sequence: confirmation.sequence); return }
        let presentation = model.quickSend.presentationID
        confirmationDismissal?.cancel()
        confirmationDismissal = Task {
            do { try await Task.sleep(for: .milliseconds(700)) }
            catch { return }
            guard model.quickSend.presentationID == presentation, self.session === session else { return }
            if model.quickSend.replyTarget == nil, incoming?.hasPendingContent == true {
                session.beginPresentation()
                applyIncoming()
                return
            }
            model.quickSend.dismiss()
        }
    }
}

private struct QuickSendChannelChooser: View {
    let channels: [Channel]
    let history: QuickSendTargetHistory?
    let selectedID: String?
    let choose: (Channel) -> Void
    @ViewState private var query = ""
    @ViewState private var highlightedID: String?
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss

    private var matches: [Channel] {
        history?.choices(channels: channels, query: query) ?? channels.filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
                || $0.purpose?.localizedStandardContains(query) == true
                || $0.directory?.localizedStandardContains(query) == true
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search Channels", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .onSubmit(selectHighlighted)
            if matches.isEmpty {
                Text(query.isEmpty ? "No channels yet" : "No channels found")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44)
            } else {
                List(matches, selection: $highlightedID) { channel in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(channel.name).lineLimit(1)
                            if let purpose = channel.purpose, !purpose.isEmpty {
                                Text(purpose).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if channel.id == selectedID {
                            Image(systemName: "checkmark").foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { choose(channel) }
                    .tag(channel.id)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { choose(channel) }
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(matches.count) * 44 + 8, 252))
            }
        }
        .font(.system(size: 13))
        .padding(10)
        .frame(width: 340)
        .onAppear { searching = true; highlightedID = selectedID ?? matches.first?.id }
        .onChange(of: query) { _, _ in highlightedID = matches.first?.id }
        .onExitCommand { dismiss() }
        .onKeyPress(.return) { selectHighlighted(); return .handled }
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
    }

    private func selectHighlighted() {
        if let channel = matches.first(where: { $0.id == highlightedID }) ?? matches.first { choose(channel) }
    }

    private func moveHighlight(_ offset: Int) {
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == highlightedID } ?? 0
        highlightedID = matches[max(0, min(index + offset, matches.count - 1))].id
    }
}
