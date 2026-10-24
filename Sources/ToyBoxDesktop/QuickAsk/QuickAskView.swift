import ChannelClient
import ChannelKit
import SwiftUI
import UniformTypeIdentifiers

struct QuickAskView: View {
    var lastUsedChannel: () -> String? = { nil }
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("textScale") private var textScale = 1.0
    @ViewState private var history: QuickAskTargetHistory?
    @ViewState private var selectedID: String?
    @ViewState private var sessions: [String: AuxiliaryComposerSession] = [:]
    @ViewState private var heldStore: ChannelStore?
    @ViewState private var showsChooser = false
    @ViewState private var focusID = UUID()
    @ViewState private var confirmationDismissal: Task<Void, Never>?
    @ViewState private var isDragging = false

    private var channels: [Channel] { model.catalog?.channels ?? [] }
    private var session: AuxiliaryComposerSession? { selectedID.flatMap { sessions[$0] } }
    private var channelName: String {
        guard let selectedID else { return "Choose Channel" }
        return channels.first { $0.id == selectedID }?.name ?? session?.store.details?.name
            ?? history?.name(for: selectedID) ?? "Saved Channel"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            header
            if let session {
                AuxiliaryComposer(
                    session: session, style: .quickAsk, isPresented: model.quickAsk.isPresented,
                    presentationID: focusID, onConfirmed: { confirmed($0, session: session) },
                    onOpenChannel: { open(session) }, onDismiss: model.quickAsk.dismiss,
                    onChooseChannel: { showsChooser = true }, onDraggingChanged: { isDragging = $0 }
                )
                .id(ObjectIdentifier(session))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose a channel to start a message.")
                        .foregroundStyle(.secondary)
                    if let error = model.catalog?.error ?? model.configurationError {
                        Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Retry") { Task { await model.catalog?.refresh() } }
                    } else if model.catalog?.isLoading == true {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
            }
            if let error = history?.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
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
        .onChange(of: model.quickAsk.isPresented, initial: true) { _, presented in
            if presented { beginPresentation() }
            else { endPresentation() }
        }
        .onChange(of: model.quickAsk.presentationID) { _, _ in focusID = UUID() }
        .onChange(of: model.catalog?.hasLoaded) { _, loaded in
            if loaded == true, model.quickAsk.isPresented, selectedID == nil { chooseInitialTarget() }
        }
        .onChange(of: selectedID) { _, _ in holdSelectedStore() }
        .onChange(of: session?.draft.revision) { _, _ in trackDraft() }
        .onChange(of: model.serverURL) { _, _ in
            confirmationDismissal?.cancel()
            for session in sessions.values { session.cancelOpenOnConfirmation() }
            model.quickAsk.dismiss()
            endPresentation()
            sessions = [:]
            selectedID = nil
            history = nil
        }
        .onDisappear { endPresentation() }
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
                QuickAskChannelChooser(channels: history?.choices(channels: channels, query: "") ?? channels,
                                       history: history, selectedID: selectedID) { channel in
                    select(channel, explicitly: true)
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
        if history == nil, let api = model.api { history = .init(serverURL: api.baseURL) }
        chooseInitialTarget()
        holdSelectedStore()
        focusID = UUID()
    }

    private func chooseInitialTarget() {
        if let selectedID {
            installSession(channelID: selectedID)
            return
        }
        guard let api = model.api else { showsChooser = true; return }
        let target = history?.initialTarget(channels: channels,
                                           lastUsedID: model.activeChannelID ?? lastUsedChannel()) {
            ComposerDraft.shared(serverURL: api.baseURL, channelID: $0, scope: .quickAsk).hasContent
        }
        if let target {
            selectedID = target
            installSession(channelID: target)
        } else {
            showsChooser = model.catalog?.hasLoaded == true
        }
    }

    private func select(_ channel: Channel, explicitly: Bool) {
        confirmationDismissal?.cancel()
        if explicitly { history?.choose(channel) }
        selectedID = channel.id
        installSession(channelID: channel.id)
        trackDraft()
        holdSelectedStore()
    }

    private func installSession(channelID: String) {
        guard sessions[channelID] == nil, let catalog = model.catalog else { return }
        sessions[channelID] = AuxiliaryComposerSession(store: catalog.channel(id: channelID), scope: .quickAsk)
    }

    private func holdSelectedStore() {
        let next = model.quickAsk.isPresented ? session?.store : nil
        guard heldStore !== next else { return }
        if let heldStore { model.release(heldStore) }
        heldStore = next
        if let next { model.acquire(next) }
    }

    private func trackDraft() {
        guard let selectedID, let session else { return }
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

    private func open(_ session: AuxiliaryComposerSession) {
        guard model.api?.baseURL == session.store.api.baseURL else { return }
        model.quickAsk.dismiss()
        model.activate(channelID: session.store.id)
    }

    private func confirmed(_ confirmation: AuxiliaryComposerSession.Confirmation,
                           session: AuxiliaryComposerSession) {
        guard model.api?.baseURL == session.store.api.baseURL else { return }
        trackDraft()
        if confirmation.opensChannel { open(session); return }
        guard model.quickAsk.isPresented, self.session === session else { return }
        let presentation = model.quickAsk.presentationID
        confirmationDismissal?.cancel()
        confirmationDismissal = Task {
            do { try await Task.sleep(for: .milliseconds(700)) }
            catch { return }
            guard model.quickAsk.presentationID == presentation, self.session === session else { return }
            model.quickAsk.dismiss()
        }
    }
}

private struct QuickAskChannelChooser: View {
    let channels: [Channel]
    let history: QuickAskTargetHistory?
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
                Text(query.isEmpty ? "No channels available" : "No matching channels")
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
