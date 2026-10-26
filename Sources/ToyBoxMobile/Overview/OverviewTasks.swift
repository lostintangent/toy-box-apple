import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct OverviewTasksSection: View {
    let store: ChannelStore

    var body: some View {
        let progress = channelTasksProgress(store.tasks)
        Section {
            if store.tasks.isEmpty {
                Text("No tasks yet").foregroundStyle(.secondary)
            } else {
                ForEach(store.tasks) { task in
                    OverviewTaskRow(task: task, agents: store.roster, artifacts: store.artifacts)
                }
            }
        } header: {
            HStack {
                Text("Tasks · \(progress.done)/\(progress.total)")
                Spacer()
                if let diff = channelTasksDiff(store.tasks) { OverviewTaskDiff(diff: diff) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct OverviewTaskRow: View {
    let task: ChannelTask
    let agents: [ChannelAgent]
    let artifacts: [ChannelArtifact]
    @Environment(ChannelArtifactSession.self) private var viewer
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var expanded: Bool

    init(task: ChannelTask, agents: [ChannelAgent], artifacts: [ChannelArtifact]) {
        self.task = task
        self.agents = agents
        self.artifacts = artifacts
        _expanded = ViewState(initialValue: task.isExpandedByDefault)
    }

    var body: some View {
        Group {
            if let children = task.children, !children.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(children) { OverviewTaskRow(task: $0, agents: agents, artifacts: artifacts) }
                } label: {
                    header
                }
            } else {
                header
            }
        }
        .onChange(of: task.status) { _, _ in expanded = task.isExpandedByDefault }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                status.accessibilityLabel(task.statusDescription)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).foregroundStyle(task.status == "done" ? .secondary : .primary)
                    if task.showsChildProgress {
                        let progress = channelTasksProgress(task.children ?? [])
                        Text("\(progress.done)/\(progress.total) subtasks").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let id = task.ownerId {
                let owner = channelAgentIdentity(agents, id: id)
                HStack(spacing: 6) {
                    AgentAvatarView(agent: owner, size: 16)
                    Text(owner.name).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if task.status != "pending", let diff = channelTasksDiff([task]) { OverviewTaskDiff(diff: diff) }
            if task.startedAt.flatMap(ChannelDates.date) != nil {
                TimelineView(.everyMinute) { context in
                    if let timing = channelTaskTiming(task, now: context.date) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("\(timing.elapsedMinutes) min elapsed", systemImage: "clock")
                            if let remaining = timing.checkInMinutes {
                                Label(remaining == 0 ? "Check-in due" : "Check-in in \(remaining) min", systemImage: "bell")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
            }
            if let id = task.artifactId {
                let artifact = artifacts.first { $0.id == id }
                Button {
                    if let artifact { viewer.open(artifact) }
                } label: {
                    Label(artifact?.title ?? "Artifact unavailable", systemImage: "doc.text")
                        .font(.footnote)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .disabled(artifact == nil)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var status: some View {
        switch task.status {
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(ChannelTaskColors.changes(in: colorScheme).added)
        case "blocked":
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
        case "in_progress":
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
        default:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

private struct OverviewTaskDiff: View {
    let diff: DiffStats
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = ChannelTaskColors.changes(in: colorScheme)
        HStack(spacing: 6) {
            Text("+\(diff.added.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))")
                .foregroundStyle(colors.added)
            Text("\u{2212}\(diff.removed.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))")
                .foregroundStyle(colors.removed)
        }
        .font(.footnote.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(diff.added) additions, \(diff.removed) deletions")
    }
}
