import ChannelClient
import ChannelKit
import SwiftUI

/// Artifacts, tasks and the preview above the composer input, with its own hairline. It reads only
/// those slices of the store, so the input doesn't redraw when they change.
struct ComposerTray: View {
    let store: ChannelStore
    @Environment(ArtifactOpener.self) private var artifactOpener
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.windowSnapshot) private var snapshot
    @ViewState private var showArtifacts = false
    @ViewState private var showTasks = false

    private var artifacts: [ChannelArtifact] { Array(store.artifacts.reversed()) }
    private var progress: TaskProgress { channelTasksProgress(store.tasks) }

    var body: some View {
        let preview = store.details?.resolvedPreview
        if Self.isVisible(artifacts: store.artifacts, tasks: store.tasks, preview: preview) {
            VStack(spacing: 0) {
                row(preview: preview)
                ComposerHairline()
            }
        }
    }

    private func row(preview: ChannelPreview?) -> some View {
        HStack(spacing: 8) {
            if let newest = artifacts.first {
                ViewThatFits(in: .horizontal) {
                    Button { artifactOpener.open(newest) } label: {
                        Label(newest.title, systemImage: "doc.text")
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: 230, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    artifactOverflow
                }
                .layoutPriority(-1)
                if artifacts.count > 1 {
                    Button { showArtifacts.toggle() } label: {
                        Text("+\(artifacts.count - 1)").frame(minWidth: 28, minHeight: 28)
                    }
                    .accessibilityLabel("Show all \(artifacts.count) artifacts")
                    .popover(isPresented: $showArtifacts, arrowEdge: .top) { artifactList }
                }
            }
            Spacer(minLength: 0)
            if !store.tasks.isEmpty {
                Button { showTasks.toggle() } label: {
                    Label("Tasks \(progress.done)/\(progress.total)", systemImage: "checklist")
                        .lineLimit(1)
                        .frame(minHeight: 28)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .popover(isPresented: $showTasks, arrowEdge: .top) {
                    ComposerTasksPopover(tasks: store.tasks, agents: store.roster,
                                         artifacts: store.artifacts) { artifact in
                        showTasks = false
                        artifactOpener.open(artifact)
                    }
                }
                .help("\(progress.done) of \(progress.total) top-level tasks complete")
                .accessibilityLabel("Tasks")
                .accessibilityValue("\(progress.done) of \(progress.total) done")
            }
            if let preview { previewButton(preview) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(height: 28)
        .padding(.horizontal, 12)
        .task(id: snapshot?.requestedState) {
            switch snapshot?.requestedState {
            case "composer-tasks":
                guard !store.tasks.isEmpty else {
                    snapshot?.failState("composer-tasks", message: "This channel has no tasks.")
                    return
                }
                showTasks = true
                snapshot?.markStateReady("composer-tasks")
            case "composer-artifacts":
                guard artifacts.count > 1 else {
                    snapshot?.failState("composer-artifacts", message: "This channel has no additional artifacts.")
                    return
                }
                showArtifacts = true
                snapshot?.markStateReady("composer-artifacts")
            default: break
            }
        }
    }

    static func isVisible(artifacts: [ChannelArtifact], tasks: [ChannelTask], preview: ChannelPreview?) -> Bool {
        !artifacts.isEmpty || !tasks.isEmpty || preview != nil
    }

    private var artifactOverflow: some View {
        Menu {
            ForEach(artifacts) { artifact in
                Button(artifact.title) { artifactOpener.open(artifact) }
            }
        } label: {
            Label("Artifacts", systemImage: "doc.text")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Shared artifacts")
    }

    private var artifactList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Artifacts").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(artifacts) { artifact in
                        Button {
                            showArtifacts = false
                            artifactOpener.open(artifact)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(artifact.title).lineLimit(2)
                                    if let sharedAt = artifact.sharedAt, let date = ChannelDates.date(sharedAt) {
                                        Text("Shared \(date.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .frame(maxHeight: 420)
        .trayPopoverContent()
    }

    @ViewBuilder private func previewButton(_ preview: ChannelPreview) -> some View {
        if preview.kind == "url", let address = preview.url, let url = store.api.resourceURL(address) {
            Button { openURL(url) } label: {
                Label("Preview", systemImage: "arrow.up.right.square").lineLimit(1)
            }
            .help("Open preview in your browser: \(url.absoluteString)")
        } else if preview.kind == "screen" {
            Button {
                if let url = model.channelURL(channelID: store.id) { openURL(url) }
            } label: {
                Label("Screen", systemImage: "display").lineLimit(1)
            }
            .help("Open screen preview in Toy Box")
            .accessibilityLabel("Open screen preview in Toy Box")
        }
    }
}

/// The tray's task popover. Its heading and root task status icons share one leading inset, and
/// parent disclosures trail their titles inline, as in the inspector.
struct ComposerTasksPopover: View {
    static let width: CGFloat = 360
    static let inset: CGFloat = 16

    let tasks: [ChannelTask]
    let agents: [ChannelAgent]
    let artifacts: [ChannelArtifact]
    let onArtifactOpen: (ChannelArtifact) -> Void

    var body: some View {
        let progress = channelTasksProgress(tasks)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tasks").font(.headline)
                Spacer()
                Text("\(progress.done)/\(progress.total)").foregroundStyle(.secondary)
            }
            .padding(.horizontal, Self.inset)
            ScrollView {
                OverviewTaskList(tasks: tasks, agents: agents, artifacts: artifacts, onArtifactOpen: onArtifactOpen)
                    .padding(.horizontal, Self.inset)
            }
        }
        .padding(.vertical, Self.inset)
        .frame(width: Self.width)
        .frame(maxHeight: 420)
        .trayPopoverContent()
    }
}

private extension View {
    /// A popover inherits the environment of the control it hangs from, so tray popovers reset the
    /// tray's 12-point secondary label styling to body text in primary ink.
    func trayPopoverContent() -> some View {
        font(.body).foregroundStyle(Color.primary)
    }
}
