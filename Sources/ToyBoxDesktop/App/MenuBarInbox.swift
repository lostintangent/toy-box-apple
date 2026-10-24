import AppKit
import ChannelClient
import ChannelKit
import SwiftUI

struct MenuBarInbox: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.channelTextScale) private var textScale
    @ViewState private var inbox = MenuBarInboxState()
    @ViewState private var isPresented = false
    @ViewState private var presentationID = UUID()
    @ViewState private var expandedChannelID: String?
    @ViewState private var replySession: AuxiliaryComposerSession?
    @ViewState private var holdsReplyConnection = false
    @ViewState private var replyError: String?
    @ViewState private var bodyHeight: CGFloat = 160
    @ViewState private var maximumHeight: CGFloat = 640
    @ViewState private var window = MenuBarInboxWindowReference()

    var body: some View {
        let status = model.menuBarStatus
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    contents(status)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
                }
                .frame(height: min(bodyHeight, max(maximumHeight - 81, 0)))
                .onChange(of: expandedChannelID) { _, id in
                    if let id { proxy.scrollTo("reply-\(id)", anchor: .bottom) }
                }
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .background {
            MenuBarInboxWindowObserver { attached in
                window.value = attached
                maximumHeight = min(640, (attached.screen?.visibleFrame.height ?? 664) - 24)
            } onVisibility: { visible in
                presentationChanged(visible)
            }
        }
        .onChange(of: status) { _, status in
            guard isPresented else { return }
            inbox.update(status)
            if let session = replySession,
               let request = inbox.requests.first(where: { $0.id == session.store.id }),
               request.state == .answered || request.state == .newerRequest {
                session.invalidateRequest(replacementSequence: status.waiting.first { $0.id == request.id }?.sequence)
            }
        }
        .onChange(of: model.serverURL) { _, _ in
            replySession?.cancelOpenOnConfirmation()
            close()
            collapseReply()
        }
        .onAppear { presentationChanged(true) }
        .onDisappear { presentationChanged(false) }
        .onExitCommand {
            if expandedChannelID != nil { collapseReply() }
            else { close() }
        }
        .accessibilityLabel("Toy Box inbox")
    }

    @ViewBuilder
    private func contents(_ status: MenuBarStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.configurationError != nil {
                empty(title: "Connect to Toy Box", detail: "Set a server in Settings to send a message.")
                Button("Open Settings") { closeThen { openSettingsWindow() } }
            } else {
                if let host = status.unreachableHost {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Offline. Requests may be out of date.")
                            .font(.system(size: 12))
                            .help(model.catalog?.error ?? "Can't connect to \(host)")
                        Button("Retry") { model.refreshCatalog() }
                            .controlSize(.small)
                    }
                }
                if let replyError {
                    Label(replyError, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                }
                if !inbox.requests.isEmpty {
                    waiting
                }
                if !status.working.isEmpty {
                    if !inbox.requests.isEmpty { Divider() }
                    working(status.workingSection, total: status.working.count)
                }
                if inbox.requests.isEmpty && status.working.isEmpty {
                    if model.catalog?.hasLoaded == false && status.unreachableHost == nil {
                        Text("Connecting…").font(.system(size: 13)).foregroundStyle(.secondary)
                    } else if model.catalog?.channels.isEmpty == true && status.unreachableHost == nil {
                        empty(title: "No channels yet", detail: "Open Toy Box Desktop to create one.")
                    } else if status.unreachableHost == nil {
                        Text("Your Team").font(.system(size: 15, weight: .semibold))
                        empty(title: "All caught up", detail: "No requests waiting. No agents are working.")
                    }
                }
            }
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Waiting for You").font(.system(size: 15, weight: .semibold))
                Text("\(model.menuBarStatus.waiting.count)")
                    .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(Array(inbox.requests.enumerated()), id: \.element.id) { index, request in
                if index > 0 { Divider().padding(.leading, 38) }
                requestRow(request)
            }
        }
    }

    private func requestRow(_ request: MenuBarInboxState.Request) -> some View {
        let item = request.item
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if let agent = item.agent {
                    AgentAvatarView(agent: agent, size: 28)
                } else {
                    Image(systemName: "questionmark.bubble")
                        .foregroundStyle(.secondary).frame(width: 28, height: 28).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Button(item.name) { open(item) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .help("Open \(item.name)")
                    Text(item.agent.map { "\($0.name) needs your reply" } ?? "Waiting for your reply")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { open(item) } label: {
                    Image(systemName: "arrow.up.forward.app").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Open \(item.name)")
                .help("Open \(item.name)")
            }
            VStack(alignment: .leading, spacing: 8) {
                if let quote = item.quote {
                    Text(quote)
                        .font(.system(size: 13 * textScale))
                        .lineSpacing(2)
                        .accessibilityLabel(quote)
                } else {
                    Text("Request preview unavailable")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Button("Retry") { model.retryMenuBarRequest(channelID: item.id) }
                        .controlSize(.small)
                }
                if let notice = request.state.notice {
                    Label(notice, systemImage: request.state == .sent ? "checkmark.circle" : "info.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if request.state != .sent {
                        Button("Open Channel") { open(item) }.controlSize(.small)
                    }
                }
                if expandedChannelID == item.id {
                    if let replySession {
                        AuxiliaryComposer(
                            session: replySession, style: .reply, isPresented: isPresented,
                            presentationID: presentationID,
                            onConfirmed: { confirmation in confirmedReply(confirmation, to: item) },
                            onOpenChannel: { open(item) },
                            onDismiss: collapseReply
                        )
                        .id("reply-\(item.id)")
                    }
                } else if request.canReply {
                    Button {
                        expandReply(to: item)
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .frame(minHeight: 28)
                    .accessibilityLabel("Reply to \(item.agent?.name ?? item.name) in \(item.name)")
                }
            }
            .padding(.leading, 38)
        }
    }

    private func working(_ section: MenuBarStatus.Section, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Working Now").font(.system(size: 12, weight: .semibold))
                Text("\(total)").font(.system(size: 12)).monospacedDigit()
            }
            .foregroundStyle(.secondary)
            ForEach(section.items) { item in
                Button {
                    closeThen { model.activate(channelID: item.id) }
                } label: {
                    HStack(spacing: 10) {
                        AgentAvatarStack(agents: item.agents, size: 20, showsOverflow: false)
                            .frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 40)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if section.overflow > 0 {
                Button("Open \(section.overflow) more working channels…") {
                    closeThen { model.activate(channelID: nil) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minHeight: 28)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                closeThen { model.quickSend.present() }
            } label: {
                HStack {
                    Label("Quick Send…", systemImage: "square.and.pencil")
                    Spacer()
                    if let shortcut = model.quickSend.shortcut {
                        Text(shortcut.displayName).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 32)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            HStack {
                Button("Open Toy Box Desktop") { closeThen { model.activate(channelID: nil) } }
                    .buttonStyle(.plain)
                    .frame(height: 32)
                Spacer()
                Button {
                    closeThen { openSettingsWindow() }
                } label: {
                    Image(systemName: "gearshape").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func empty(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func presentationChanged(_ visible: Bool) {
        guard visible != isPresented else { return }
        isPresented = visible
        model.menuBar.popoverVisibilityChanged(visible)
        if visible {
            collapseReply()
            replyError = nil
            inbox = MenuBarInboxState(status: model.menuBarStatus)
            presentationID = UUID()
        } else {
            releaseReplyConnection()
        }
    }

    private func expandReply(to item: MenuBarStatus.Item) {
        guard let sequence = item.sequence, let requester = item.agent else {
            replyError = "Request preview unavailable. Open the channel to review it."
            return
        }
        guard let catalog = model.catalog, catalog.channels.contains(where: { $0.id == item.id }) else {
            replyError = "This channel is no longer available. Your draft is saved."
            return
        }
        let store = catalog.channel(id: item.id)
        collapseReply()
        replyError = nil
        replySession = AuxiliaryComposerSession(store: store, scope: .inboxReply(sequence: sequence), requester: requester)
        model.acquire(store)
        holdsReplyConnection = true
        expandedChannelID = item.id
    }

    private func collapseReply() {
        releaseReplyConnection()
        expandedChannelID = nil
        replySession = nil
    }

    private func releaseReplyConnection() {
        guard holdsReplyConnection, let replySession else { return }
        model.release(replySession.store)
        holdsReplyConnection = false
    }

    private func confirmedReply(_ confirmation: AuxiliaryComposerSession.Confirmation, to item: MenuBarStatus.Item) {
        guard let replySession, model.serverURL == replySession.store.api.baseURL.absoluteString else { return }
        inbox.confirmed(item.id)
        if confirmation.opensChannel {
            closeThen { model.activate(channelID: item.id, sequence: confirmation.sequence) }
        }
    }

    private func open(_ item: MenuBarStatus.Item) {
        closeThen { model.activate(channelID: item.id, sequence: item.sequence) }
    }

    private func openSettingsWindow() {
        NSApp.activate()
        openSettings()
    }

    private func close() {
        window.value?.orderOut(nil)
        presentationChanged(false)
    }

    private func closeThen(_ action: @escaping @MainActor () -> Void) {
        close()
        DispatchQueue.main.async(execute: action)
    }
}

@MainActor
private final class MenuBarInboxWindowReference {
    weak var value: NSWindow?
}

private struct MenuBarInboxWindowObserver: NSViewRepresentable {
    var onAttach: (NSWindow) -> Void
    var onVisibility: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onAttach = onAttach
        view.onVisibility = onVisibility
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onAttach = onAttach
        view.onVisibility = onVisibility
    }

    final class ObserverView: NSView {
        var onAttach: ((NSWindow) -> Void)?
        var onVisibility: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                if let window { self?.onAttach?(window) }
            }
            observation = window.observe(\.isVisible, options: [.initial, .new]) { [weak self] _, change in
                let visible = change.newValue == true
                DispatchQueue.main.async { self?.onVisibility?(visible) }
            }
        }
    }
}
