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
                                        api: store.api, channelID: store.id)
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
        }
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct OverviewArtifactSymbol: View {
    let artifact: ChannelArtifact
    let size: CGFloat

    var body: some View {
        Image(systemName: ChannelArtifactSymbol.name(for: ArtifactContentKind(artifact)))
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
    let api: ChannelAPI
    let channelID: String
    @Environment(ChannelArtifactSession.self) private var viewer
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(\.openURL) private var openURL
    @ViewState private var original: URL?
    @ViewState private var preview: URL?
    @ViewState private var sharing: ArtifactShare?
    @ViewState private var preparing = false
    @ViewState private var error: String?

    private var resource: URL? { artifact.url.flatMap(api.resourceURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { viewer.open(artifact) } label: {
                OverviewArtifactLabel(artifact: artifact, share: share, preparing: preparing)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("artifact-\(artifact.id)")
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
                    guard let url = api.channelURL(channelID: channelID, files: [artifact.file]) else {
                        error = "The Toy Box editor link is unavailable."
                        return
                    }
                    openURL(url) { accepted in
                        if !accepted { error = "The Toy Box editor could not be opened." }
                    }
                }
            }
            if let error { ManagementError(message: error) }
        }
        .quickLookPreview($preview)
        .sheet(item: $sharing) { ArtifactShareSheet(file: $0.file) { error = $0 } }
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
