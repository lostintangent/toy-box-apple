import AppKit
import ChannelClient
import ChannelKit
import QuickLook
import SwiftUI
import ToyBoxUI
import UniformTypeIdentifiers

/// A shared file: its real Finder icon, the title, and who shared it and when.
struct OverviewArtifactRow: View {
    private enum Focus { case row, menu }

    @Environment(AppModel.self) private var app
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let artifact: ChannelArtifact
    /// Names the artifact for this visit to the channel. See `OverviewSlots`.
    let key: String
    let share: ChannelArtifactShare?
    let agents: [ChannelAgent]
    let store: ChannelStore
    let open: () -> Void
    @ViewState private var quickLook = OverviewItemState(QuickLook())
    /// The row stays until the stream reports the removal, so only the request is pending here.
    @ViewState private var removing = OverviewItemState(false)
    /// A removal gets its own recovery when it first fails.
    @ViewState private var recoveries = OverviewItemState<ChannelManagementWriteRecovery?>(nil)
    @ViewState private var isHovering = false
    @FocusState private var focus: Focus?

    private struct QuickLook {
        var file: URL?
        var isFetching = false
        var error: String?
    }

    private var api: ChannelAPI { store.api }
    private var isFetching: Bool { quickLook[key].isFetching }
    private var error: String? { quickLook[key].error }
    private var isRemoving: Bool { removing[key] }
    private var recovery: ChannelManagementWriteRecovery? { recoveries[key] }
    private var canRemove: Bool { !isRemoving && recovery?.blocksWrites != true && store.phase.isConnected }
    private var showsMenu: Bool { isHovering || focus != nil || voiceOver }
    private var previewFile: Binding<URL?> {
        Binding(get: { quickLook[key].file }, set: { quickLook[key].file = $0 })
    }

    private var resource: URL? { artifact.url.flatMap(api.resourceURL) }
    private var type: UTType? {
        let pathExtension = (artifact.file.path as NSString).pathExtension
        return pathExtension.isEmpty ? nil : UTType(filenameExtension: pathExtension)
    }
    private var sharedDate: Date? { (share?.sharedAt ?? artifact.sharedAt).flatMap(ChannelDates.date) }

    /// The sharer from the latest loaded share event, or the localized file type when it is not loaded.
    private var source: String {
        if let actor = share?.actor {
            switch actor.type {
            case "user": return "You"
            case "agent": if let id = actor.agentId { return channelAgentIdentity(agents, id: id).name }
            default: break
            }
        }
        return type?.localizedDescription ?? "Document"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(for: type ?? .data))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(artifact.title)
                                .font(.system(size: 13 * textScale))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            TimelineView(.everyMinute) { context in
                                Text(subtitle(now: context.date))
                                    .font(.system(size: 11 * textScale))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if isFetching {
                            ProgressView().controlSize(.mini).accessibilityLabel("Preparing Quick Look")
                        }
                        if isRemoving {
                            ProgressView().controlSize(.mini).accessibilityLabel("Removing from channel")
                        }
                    }
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focus, equals: .row)
                .help(help)
                .onKeyPress(.space) {
                    showQuickLook()
                    return .handled
                }
                .onKeyPress(.return) {
                    open()
                    return .handled
                }
                .accessibilityLabel(artifact.title)
                .accessibilityValue(subtitle(now: .now))
                .accessibilityActions { actions }
                OverviewRowMenu(title: "Actions for \(artifact.title)", isVisible: showsMenu) { actions }
                    .focused($focus, equals: .menu)
            }
            .onHover { isHovering = $0 }
            .contextMenu { actions }
            if let error { ManagementError(message: error).padding(.leading, 38) }
            if let error = recovery?.error { ManagementError(message: error).padding(.leading, 38) }
            if let recovery, let state = recovery.state {
                ManagementRecoveryNotice(
                    state: state, reviewTitle: "I've Reviewed the Conversation",
                    onCheck: { Task { await checkCurrentState(recovery) } },
                    onReview: recovery.finishReview)
                .padding(.leading, 38)
            }
        }
        .quickLookPreview(previewFile)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Open", action: open)
        Button("Quick Look", action: showQuickLook).disabled(resource == nil || isFetching)
        Button("Show in Transcript") {
            if let sequence = share?.sequence { interaction.reveal(sequence: sequence) }
        }
        .disabled(share == nil)
        Divider()
        Button("Copy Link") {
            guard let resource else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(resource.absoluteString, forType: .string)
        }
        .disabled(resource == nil)
        Divider()
        Button("Remove from Channel", role: .destructive, action: remove).disabled(!canRemove)
    }

    private func subtitle(now: Date) -> String {
        guard let sharedDate else { return source }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .short
        // The row updates each minute, so anything newer reads "now" rather than a stale seconds count.
        let date = now.timeIntervalSince(sharedDate) < 60 ? now : sharedDate
        return "\(source) · \(formatter.localizedString(for: date, relativeTo: now))"
    }

    private var help: String {
        var lines = [artifact.title, artifact.file.path]
        if let sharedDate { lines.append("Shared \(sharedDate.formatted(date: .complete, time: .shortened))") }
        return lines.joined(separator: "\n")
    }

    private func showQuickLook() {
        guard !isFetching else { return }
        guard let resource else {
            quickLook[key].error = "The server did not provide a usable resource URL for this artifact."
            return
        }
        quickLook[key].isFetching = true
        quickLook[key].error = nil
        Task { [key, artifact] in
            var result = QuickLook()
            do {
                result.file = try await ArtifactDownload.file(for: artifact, from: resource)
            } catch is CancellationError {
            } catch {
                result.error = error.localizedDescription
            }
            quickLook.update(key) { $0 = result }
        }
    }

    /// Sends the removal once. The row leaves only when the stream reports it, never on this response.
    private func remove() {
        guard canRemove else { return }
        let recovery = self.recovery ?? ChannelManagementWriteRecovery()
        recoveries[key] = recovery
        removing[key] = true
        recovery.clearError()
        Task { [key, artifact] in
            do {
                try await api.removeArtifact(channelId: store.id, artifactId: artifact.id)
            } catch {
                if recovery.record(error) { await checkCurrentState(recovery) }
            }
            removing.update(key) { $0 = false }
        }
    }

    private func checkCurrentState(_ recovery: ChannelManagementWriteRecovery) async {
        await recovery.check(catalog: app.catalog, channelId: store.id) { current in
            if current.channelWasDeleted {
                return "The channel is no longer present on the server."
            }
            return "Channel details have been refreshed. This artifact may already be removed. Review the current conversation before removing it again."
        }
    }
}
