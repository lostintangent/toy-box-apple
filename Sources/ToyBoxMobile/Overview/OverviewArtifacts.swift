import ChannelClient
import ChannelKit
import QuickLook
import SwiftUI
import ToyBoxUI
import UIKit

struct OverviewArtifactsSection: View {
    let store: ChannelStore
    let session: OverviewSession

    var body: some View {
        OverviewSectionRows(summary: .artifacts(store.artifacts.count), section: .artifacts, session: session) {
            if store.artifacts.isEmpty {
                Text("Nothing shared yet").foregroundStyle(ChannelInk.secondary)
                    .modifier(OverviewListRowBoundary(isLast: true))
            } else {
                let artifacts = channelArtifactsNewestFirst(store.artifacts)
                ForEach(artifacts) { artifact in
                    OverviewArtifactRow(artifact: artifact, share: store.artifactShares[artifact.file.id],
                                        store: store, state: session.artifact(artifact.id))
                        .listRowInsets(.vertical, 6)
                        .modifier(OverviewListRowBoundary(isLast: artifact.id == artifacts.last?.id))
                }
            }
        }
    }
}

struct OverviewArtifactList: View {
    let store: ChannelStore
    let onOpen: (ChannelArtifact) -> Void

    var body: some View {
        Group {
            if store.artifacts.isEmpty {
                ContentUnavailableView("No Artifacts Yet", systemImage: "doc",
                                       description: Text("Files shared by this team will appear here.")
                                        .foregroundStyle(ChannelInk.secondary))
            } else {
                List(channelArtifactsNewestFirst(store.artifacts)) { artifact in
                    Button { onOpen(artifact) } label: {
                        OverviewArtifactLabel(artifact: artifact, share: store.artifactShares[artifact.file.id])
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(.vertical, 6)
                    .accessibilityIdentifier("artifact-list-\(artifact.id)")
                }
            }
        }
        .accessibilityIdentifier("overview-artifact-list")
    }
}

struct OverviewArtifactLabel: View {
    let artifact: ChannelArtifact
    let share: ChannelArtifactShare?
    var preparing = false
    var removing = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var iconSize = 22
    @ScaledMetric(relativeTo: .title2) private var iconLane = 24

    var body: some View {
        HStack(spacing: 12) {
            OverviewArtifactSymbol(artifact: artifact, size: iconSize)
                .frame(width: iconLane)
            VStack(alignment: .leading, spacing: 4) {
                Text(artifact.title).font(.body).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                if let date = (share?.sharedAt ?? artifact.sharedAt).flatMap(ChannelDates.date) {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.footnote).foregroundStyle(ChannelInk.secondary)
                } else {
                    Text("Share date unavailable").font(.footnote).foregroundStyle(ChannelInk.secondary)
                }
            }
            Spacer(minLength: 0)
            if preparing { ProgressView().accessibilityLabel("Preparing original file") }
            else if removing { ProgressView().accessibilityLabel("Removing from channel") }
        }
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct OverviewArtifactSymbol: View {
    let artifact: ChannelArtifact
    let size: CGFloat

    var body: some View {
        OverviewRowSymbol(systemName: ChannelArtifactSymbol.name(for: ArtifactContentKind(artifact)), size: size)
    }
}

/// A monochrome symbol bounded to one square footprint, shared by artifact and routine rows.
struct OverviewRowSymbol: View {
    let systemName: String
    let size: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct OverviewArtifactRow: View {
    let artifact: ChannelArtifact
    let share: ChannelArtifactShare?
    let store: ChannelStore
    let state: OverviewArtifactState
    @Environment(AppModel.self) private var app
    @Environment(ChannelArtifactSession.self) private var viewer
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @ViewState private var original: URL?
    @ViewState private var preview: URL?
    @ViewState private var sharing: ArtifactShare?
    @ViewState private var preparing = false
    @ViewState private var error: String?

    private var api: ChannelAPI { store.api }
    private var resource: URL? { artifact.url.flatMap(api.resourceURL) }
    private var recovery: ChannelManagementWriteRecovery { state.recovery }
    private var canRemove: Bool { state.canRemove(connected: store.phase.isConnected) }
    private var matchingCatalog: ChannelCatalogStore? {
        app.catalog.flatMap { $0.api.baseURL == store.api.baseURL ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { viewer.open(artifact) } label: {
                OverviewArtifactLabel(artifact: artifact, share: share, preparing: preparing, removing: state.pending)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("artifact-\(artifact.id)")
            .accessibilityActions {
                Button("Remove from Channel", role: .destructive, action: remove).disabled(!canRemove)
            }
            .contextMenu {
                if let share {
                    Button("Show in Conversation", systemImage: "bubble") {
                        interaction.isInspectorPresented = false
                        interaction.reveal(sequence: share.sequence)
                    }
                }
                Button("Copy Link", systemImage: "link") {
                    if let resource { UIPasteboard.general.url = resource }
                }
                .disabled(resource == nil)
                Button("Share Original", systemImage: "square.and.arrow.up") { prepare(sharing: true) }
                    .disabled(resource == nil || preparing)
                Button("Quick Look", systemImage: "eye") { prepare(sharing: false) }
                    .disabled(resource == nil || preparing)
                Button("Open in Toy Box", systemImage: "arrow.up.forward.app") {
                    guard let url = api.channelURL(channelID: store.id, files: [artifact.file]) else {
                        error = "The Toy Box editor link is unavailable."
                        return
                    }
                    openURL(url) { accepted in
                        if !accepted { error = "The Toy Box editor could not be opened." }
                    }
                }
                Divider()
                Button("Remove from Channel", systemImage: "trash", role: .destructive, action: remove)
                    .disabled(!canRemove)
            }
            if let error { ManagementError(message: error) }
            if let message = recovery.error { ManagementError(message: message) }
            if let recoveryState = recovery.state {
                ManagementRecoveryNotice(state: recoveryState, reviewTitle: "I've Reviewed the Conversation",
                                         onCheck: { Task { await check(catalog: matchingCatalog) } },
                                         onReview: recovery.finishReview)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !voiceOver {
                Button("Remove", systemImage: "trash", role: .destructive, action: remove).disabled(!canRemove)
            }
        }
        .quickLookPreview($preview)
        .sheet(item: $sharing) { ArtifactShareSheet(file: $0.file) { error = $0 } }
    }

    /// Sends the removal once. The row leaves only when the stream reports it, never on this response.
    private func remove() {
        guard canRemove else { return }
        state.pending = true
        recovery.clearError()
        let catalog = matchingCatalog
        Task { [artifact] in
            defer { state.pending = false }
            do {
                try await api.removeArtifact(channelId: store.id, artifactId: artifact.id)
            } catch ChannelAPIError.http(status: 404, message: _) {
                // Already removed. The stream drops the row.
            } catch {
                if recovery.record(error) { await check(catalog: catalog) }
            }
        }
    }

    private func check(catalog: ChannelCatalogStore?) async {
        await recovery.check(catalog: catalog, channelId: store.id) { current in
            if current.channelWasDeleted { return "The channel is no longer present on the server." }
            return "Channel details have been refreshed. This artifact may already be removed. Review the current conversation before removing it again."
        }
    }

    private func prepare(sharing: Bool) {
        guard !preparing else { return }
        guard let resource else { error = "The artifact's resource URL is unavailable."; return }
        preparing = true
        error = nil
        Task {
            defer { preparing = false }
            do {
                let file: URL
                if let original { file = original }
                else if viewer.content?.artifact.id == artifact.id, let prepared = viewer.content?.file { file = prepared }
                else { file = try await ArtifactDownload.file(for: artifact, from: resource) }
                original = file
                if sharing { self.sharing = ArtifactShare(file: file) }
                else if QLPreviewController.canPreview(file as NSURL) { preview = file }
                else { error = "Quick Look cannot preview this file. Use Share Original to open it in another app." }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ArtifactShare: Identifiable {
    let file: URL
    var id: URL { file }
}

struct ArtifactShareSheet: UIViewControllerRepresentable {
    let file: URL
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            if let error { onError(error.localizedDescription) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
