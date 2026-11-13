import AppKit
import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UniformTypeIdentifiers

struct QuickSendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openSettings) private var openSettings
    @AppStorage("textScale") private var textScale = 1.0
    @ViewState private var history: QuickSendTargetHistory?
    @ViewState private var incoming: QuickSendPrefillInbox?
    @ViewState private var sessions: [ChannelTarget: AuxiliaryComposerSession] = [:]
    @ViewState private var replySession: AuxiliaryComposerSession?
    @ViewState private var heldStore: ChannelStore?
    @ViewState private var showsChooser = false
    @ViewState private var focusID = UUID()
    @ViewState private var isDragging = false
    @ViewState private var catalogConnectingLong = false

    private var catalogs: [ChannelCatalogStore] { model.catalogs }
    private var replyChannel: ChannelTarget? {
        model.quickSend.replyTarget.flatMap { ChannelTarget(serverURL: $0.serverURL, channelID: $0.channelID) }
    }
    private var selected: ChannelTarget? { model.quickSend.replyTarget == nil ? history?.selected : replyChannel }
    private var session: AuxiliaryComposerSession? {
        model.quickSend.replyTarget == nil ? selected.flatMap { sessions[$0] } : replySession
    }
    private var replyItem: MenuBarStatus.Item? {
        guard let replyChannel else { return nil }
        return model.menuBarStatus.waiting.first { $0.target == replyChannel }
    }
    private var hasChannels: Bool { catalogs.contains { !$0.channels.isEmpty } }
    private var showsHeader: Bool { session != nil || hasChannels }
    private var channelName: String {
        guard let selected else { return "Choose Channel" }
        return channel(selected)?.name ?? session?.store.details?.name
            ?? history?.name(for: selected) ?? "Saved Channel"
    }

    private func catalog(_ target: ChannelTarget) -> ChannelCatalogStore? { catalogs.first(at: target.serverURL) }
    private func channel(_ target: ChannelTarget) -> Channel? {
        catalog(target)?.channels.first { $0.id == target.channelID }
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
            guard let session, session.confirmation == nil else { return false }
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
        .onChange(of: catalogs.filter(\.isLoaded).map(ObjectIdentifier.init)) { _, _ in
            if model.quickSend.isPresented, selected == nil || model.quickSend.replyTarget != nil { chooseInitialTarget() }
        }
        .onChange(of: selected) { _, _ in holdSelectedStore(); applyIncoming() }
        .onChange(of: session.map(ObjectIdentifier.init)) { _, _ in holdSelectedStore() }
        .onChange(of: session?.draft.revision) { _, _ in trackDraft() }
        .onChange(of: session?.confirmation?.id) { _, _ in applyIncoming() }
        .onChange(of: incoming?.draft.isLoadingImages) { _, _ in applyIncoming() }
        .onChange(of: incoming?.draft.revision) { _, _ in applyIncoming() }
        .onChange(of: catalogs.map(ObjectIdentifier.init)) { _, _ in serversChanged() }
        .onDisappear { endPresentation() }
        .task(id: catalogs.contains(where: \.isLoaded)) {
            catalogConnectingLong = false
            guard !catalogs.isEmpty, !catalogs.contains(where: \.isLoaded) else { return }
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
        if session?.store.phase == .deleted {
            return "Shared content is saved. Choose another channel to add it."
        }
        return incoming?.draft.isLoadingImages == true ? "Adding shared images..." : nil
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            if catalogs.isEmpty {
                Text("Connect to Toy Box").font(.system(size: 15, weight: .semibold))
                Text("Set a server in Settings to send a message.").foregroundStyle(.secondary)
                Button("Open Settings") {
                    model.quickSend.dismiss()
                    NSApplication.shared.activate()
                    model.settingsTab = .servers
                    openSettings()
                }
            } else if let target = model.quickSend.replyTarget {
                let failure = replyChannel.flatMap(catalog)?.phase.message
                let unavailable = failure != nil || replyItem?.quote != nil
                Text(unavailable ? "Request preview unavailable" : "Loading request...")
                    .font(.system(size: 15, weight: .semibold))
                Text(failure ?? (unavailable
                    ? "The requester is no longer available. Open the channel to review this request."
                    : "The original request is being checked before you reply."))
                    .foregroundStyle(.secondary)
                Button("Open Channel") {
                    model.quickSend.dismiss()
                    model.activate(ChannelTarget(serverURL: target.serverURL, channelID: target.channelID),
                                   sequence: target.sequence)
                }
            } else if catalogs.allSatisfy(\.isLoaded), !hasChannels {
                Text("No channels yet").font(.system(size: 15, weight: .semibold))
                Text("Open Toy Box to create one.").foregroundStyle(.secondary)
                Button("Open Toy Box") {
                    model.quickSend.dismiss()
                    model.activate(nil)
                }
            } else if catalogs.allSatisfy({ $0.phase.message != nil }), let error = catalogs.first?.phase.message {
                Text("Offline.").font(.system(size: 15, weight: .semibold))
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Retry") { model.refreshCatalog() }
            } else if catalogs.contains(where: \.isLoaded) {
                Text("Choose a channel to start a message.").foregroundStyle(.secondary)
            } else if catalogConnectingLong {
                Text("Connecting…").foregroundStyle(.secondary)
                Button("Retry") { model.refreshCatalog() }
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
                if let history {
                    QuickSendChannelChooser(catalogs: catalogs, history: history, selected: selected,
                                           retry: model.refreshCatalog) { choice in
                        select(choice)
                        showsChooser = false
                    }
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
        if history == nil { history = .init() }
        if let api = model.api, incoming == nil { incoming = .init(serverURL: api.baseURL) }
        chooseInitialTarget()
        holdSelectedStore()
        receivePendingPrefill()
        applyIncoming()
        focusID = UUID()
    }

    private func receivePendingPrefill() {
        guard let prefill = model.quickSend.pendingPrefill,
              let server = session?.store.api.baseURL ?? model.api?.baseURL else { return }
        if incoming?.serverURL != server, incoming?.hasPendingContent != true { incoming = .init(serverURL: server) }
        incoming?.receive(prefill)
        model.quickSend.consumePrefill(id: prefill.id)
        applyIncoming()
    }

    private func applyIncoming() {
        guard model.quickSend.replyTarget == nil, let session, let target = session.store.target,
              let catalog = catalog(target), !catalog.isLoaded || channel(target) != nil,
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
        guard !catalogs.isEmpty else { showsChooser = false; return }
        history?.restoreTarget(in: catalogs, lastUsed: model.lastUsedChannel) { target in
            catalog(target).map {
                ComposerDraft.shared(serverURL: $0.api.baseURL, channelID: target.channelID, scope: .quickSend).hasContent
            } ?? false
        }
        if let selected {
            installSession(selected)
        } else {
            showsChooser = hasChannels
        }
    }

    private func select(_ choice: QuickSendTargetHistory.Choice) {
        model.quickSend.leaveReply()
        history?.choose(choice)
        installSession(choice.target)
        applyIncoming()
        trackDraft()
        holdSelectedStore()
    }

    private func installReplySession() {
        guard let target = model.quickSend.replyTarget, let catalog = replyChannel.flatMap(catalog) else { return }
        let requester = replyItem.flatMap { $0.sequence == target.sequence ? $0.agent : nil }
        if replySession?.store.target != replyChannel || replySession?.requestSequence != target.sequence {
            let draft = ComposerDraft.shared(serverURL: catalog.api.baseURL, channelID: target.channelID,
                                             scope: .inboxReply(sequence: target.sequence))
            let knownChanged = catalog.isLoaded
                && catalog.channels.first(where: { $0.id == target.channelID })?.requestSequence != target.sequence
            guard requester != nil || !draft.isNew || draft.hasContent || knownChanged else {
                replySession = nil
                return
            }
            replySession = AuxiliaryComposerSession(store: catalog.channel(id: target.channelID),
                scope: .inboxReply(sequence: target.sequence), requester: requester, draft: draft,
                isConnected: { [weak catalog] in catalog?.phase.failure == nil })
        } else if let requester {
            replySession?.seedRequesterIfNew(requester)
        }
        if catalog.isLoaded {
            let current = catalog.channels.first { $0.id == target.channelID }?.requestSequence
            if current != target.sequence { replySession?.invalidateRequest(replacementSequence: current) }
        }
    }

    private func installSession(_ target: ChannelTarget) {
        guard sessions[target] == nil, let catalog = catalog(target) else { return }
        sessions[target] = AuxiliaryComposerSession(store: catalog.channel(id: target.channelID), scope: .quickSend,
                                                    isConnected: { [weak catalog] in catalog?.phase.failure == nil })
    }

    /// A server you remove or readdress takes its editors with it, and closes Quick Send if it
    /// showed one, so it never opens a channel from a server that's gone.
    private func serversChanged() {
        let servers = Set(catalogs.map(\.api.baseURL))
        if let session, !servers.contains(session.store.api.baseURL) { model.quickSend.dismiss() }
        sessions = sessions.filter { servers.contains($0.value.store.api.baseURL) }
        if let replySession, !servers.contains(replySession.store.api.baseURL) { self.replySession = nil }
    }

    private func holdSelectedStore() {
        let next = model.quickSend.isPresented ? session?.store : nil
        guard heldStore !== next else { return }
        if let heldStore { model.release(heldStore) }
        heldStore = next
        if let next { model.hold(next) }
    }

    private func trackDraft() {
        guard model.quickSend.replyTarget == nil, let selected, let session else { return }
        history?.trackDraft(selected, name: session.store.details?.name, hasContent: session.draft.hasContent)
    }

    private func endPresentation() {
        showsChooser = false
        trackDraft()
        if let heldStore { model.release(heldStore) }
        heldStore = nil
    }

    private func open(_ session: AuxiliaryComposerSession) {
        guard catalogs.contains(where: { $0.api.baseURL == session.store.api.baseURL }) else { return }
        model.quickSend.dismiss()
        model.activate(session.store.target)
    }

    /// The message is saved, so the panel closes at once, or opens its channel for Command-Return.
    /// Shared content that arrived during the save stays open in a fresh editor instead.
    private func confirmed(_ confirmation: AuxiliaryComposerSession.Confirmation,
                           session: AuxiliaryComposerSession) {
        guard catalogs.contains(where: { $0.api.baseURL == session.store.api.baseURL }) else { return }
        trackDraft()
        guard model.quickSend.isPresented, self.session === session else { return }
        if confirmation.opensChannel { open(session); return }
        if model.quickSend.replyTarget == nil, incoming?.hasPendingContent == true {
            session.beginPresentation()
            applyIncoming()
            return
        }
        model.quickSend.dismiss()
    }
}

/// Up to three recent channels, then the rest A to Z. With several servers, each lists its own
/// under its name, and one that hasn't loaded says so with Retry.
struct QuickSendChannelChooser: View {
    let catalogs: [ChannelCatalogStore]
    let history: QuickSendTargetHistory
    let selected: ChannelTarget?
    let retry: () -> Void
    let choose: (QuickSendTargetHistory.Choice) -> Void
    @ViewState private var query = ""
    @ViewState private var highlighted: ChannelTarget?
    @ViewState private var listHeight: CGFloat?
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss

    private static let maximumListHeight: CGFloat = 252

    private var choices: (recent: [QuickSendTargetHistory.Choice], others: [[QuickSendTargetHistory.Choice]]) {
        history.choices(in: catalogs, query: query)
    }

    /// Every choice in the order the list shows them.
    private var matches: [QuickSendTargetHistory.Choice] {
        let choices = choices
        return choices.recent + choices.others.joined()
    }

    var body: some View {
        let choices = choices
        let grouped = catalogs.count > 1
        VStack(spacing: 8) {
            TextField("Search Channels", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .onSubmit(selectHighlighted)
            if matches.isEmpty, !grouped || catalogs.allSatisfy(\.isLoaded) {
                Text(query.isEmpty ? "No channels yet" : "No channels found")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44)
            } else {
                // The list's own selection is the highlight the arrow keys move.
                List(selection: $highlighted) {
                    if grouped {
                        if !choices.recent.isEmpty {
                            Section("Recent") { ForEach(choices.recent, content: row) }
                        }
                        ForEach(catalogs.indices, id: \.self) { index in
                            if !catalogs[index].isLoaded {
                                Section(catalogs[index].name) { status(catalogs[index]).listRowSeparator(.hidden) }
                            } else if !choices.others[index].isEmpty {
                                Section(catalogs[index].name) { ForEach(choices.others[index], content: row) }
                            }
                        }
                    } else {
                        ForEach(matches, content: row)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                } action: { _, height in
                    listHeight = height
                }
                .frame(height: min(listHeight ?? Self.maximumListHeight, Self.maximumListHeight))
            }
        }
        .font(.system(size: 13))
        .padding(10)
        .frame(width: 340)
        .onAppear { searching = true; highlighted = selected ?? matches.first?.target }
        .onChange(of: query) { _, _ in highlighted = matches.first?.target }
        .onExitCommand { dismiss() }
        .onKeyPress(.return) { selectHighlighted(); return .handled }
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
    }

    private func row(_ choice: QuickSendTargetHistory.Choice) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.channel.name).lineLimit(1)
                if let purpose = choice.channel.purpose, !purpose.isEmpty {
                    Text(purpose).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if choice.target == selected {
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            }
        }
        // A click anywhere in the row chooses it, including the row that's already highlighted,
        // which never changes the selection.
        .contentShape(Rectangle().inset(by: -8))
        .onTapGesture { choose(choice) }
        .tag(choice.target)
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose(choice) }
    }

    @ViewBuilder private func status(_ catalog: ChannelCatalogStore) -> some View {
        if let message = catalog.phase.message {
            HStack {
                Text(message).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Button("Retry", action: retry)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    private func selectHighlighted() {
        if let choice = matches.first(where: { $0.target == highlighted }) ?? matches.first { choose(choice) }
    }

    private func moveHighlight(_ offset: Int) {
        let matches = matches
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.target == highlighted } ?? 0
        highlighted = matches[max(0, min(index + offset, matches.count - 1))].target
    }
}
