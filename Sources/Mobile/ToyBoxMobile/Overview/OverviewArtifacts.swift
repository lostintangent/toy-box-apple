import ChannelClient
import ChannelKit
import QuickLook
import SwiftUI
import ToyBoxUI
import UIKit

struct OverviewArtifactsSection: View {
    let store: ChannelStore
    let session: ChannelOverview

    var body: some View {
        OverviewSectionRows(summary: .artifacts(store.artifacts.count), section: .artifacts, session: session) {
            if store.artifacts.isEmpty {
                Text("Nothing shared yet").foregroundStyle(ChannelInk.secondary)
                    .modifier(OverviewListRowBoundary(isLast: true))
            } else {
                let artifacts = store.artifacts.newestFirst
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

struct OverviewArtifactLabel: View {
    let artifact: ChannelArtifact
    let share: ChannelArtifact.Share?
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
                if let date = (share?.sharedAt ?? artifact.sharedAt).flatMap({ try? Date($0, strategy: .iso8601) }) {
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
    let share: ChannelArtifact.Share?
    let store: ChannelStore
    let state: ChannelOverview.Artifact
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
    private var canRemove: Bool { state.canRemove(connected: store.phase.isConnected) }

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
                let toyBox = api.channelURL(channelID: store.id, files: [artifact.file])
                Button("Open in Toy Box", systemImage: "arrow.up.forward.app") {
                    if let toyBox { openURL(toyBox) }
                }
                .disabled(toyBox == nil)
                Divider()
                Button("Remove from Channel", systemImage: "trash", role: .destructive, action: remove)
                    .disabled(!canRemove)
            }
            if let error { ManagementError(message: error) }
            if let message = state.error { ManagementError(message: message) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !voiceOver {
                // Not `.destructive`: that role collapses the row before the server's event arrives.
                Button("Remove", systemImage: "trash", action: remove)
                    .tint(.red)
                    .disabled(!canRemove)
            }
        }
        .quickLookPreview($preview)
        .sheet(item: $sharing) { ArtifactShareSheet(file: $0.file) { error = $0 } }
    }

    /// Sends the removal once. The row leaves only when the stream reports it, never on this response.
    private func remove() {
        guard canRemove else { return }
        state.pending = true
        state.error = nil
        Task { [artifact] in
            defer { state.pending = false }
            do {
                try await api.removeArtifact(channelId: store.id, artifactId: artifact.id)
            } catch ChannelAPIError.http(status: 404, message: _) {
                // Already removed. The stream drops the row.
            } catch {
                state.error = error.localizedDescription
            }
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
