import AppKit
import ChannelKit
import SwiftUI
import ToyBoxUI

private struct OverviewTaskFocusInteractionsKey: EnvironmentKey {
    static let defaultValue: FocusInteractions = .activate
}

extension EnvironmentValues {
    /// Like the routine rows' buttons, a parent task joins the key view loop only under Keyboard
    /// navigation. Tests can't turn that setting on for one process, so they host rows with `.automatic`.
    var overviewTaskFocusInteractions: FocusInteractions {
        get { self[OverviewTaskFocusInteractionsKey.self] }
        set { self[OverviewTaskFocusInteractionsKey.self] = newValue }
    }
}

/// The read-only task tree, shared by the inspector and the composer's Tasks popover. Root status
/// icons sit on the host's leading edge, so they align with its heading.
struct OverviewTaskList: View {
    /// One nesting level, so a child's status icon sits under its parent's title, as in Reminders.
    static let depthIndent: CGFloat = OverviewTaskRow.statusSize + OverviewTaskRow.titleGap

    let tasks: [ChannelTask]
    /// Identities for task owners. The store's `roster` is enough, so status updates don't redraw tasks.
    let agents: [ChannelAgent]
    let artifacts: [ChannelArtifact]
    /// The channel the tasks belong to. A list that switches to another channel reuses its rows.
    let channelId: String
    let onArtifactOpen: (ChannelArtifact) -> Void
    /// Hides each level's tasks without in-progress work. Kept tasks keep their full counts.
    let showsOnlyInProgress: Bool
    @ViewState private var slots = OverviewSlots()
    /// Owned by the list, so a parent keeps its disclosure while the filter hides and reveals it.
    @ViewState private var disclosure = ChannelTask.Disclosure()

    init(tasks: [ChannelTask], agents: [ChannelAgent], artifacts: [ChannelArtifact], channelId: String = "",
         showsOnlyInProgress: Bool = false, onArtifactOpen: @escaping (ChannelArtifact) -> Void) {
        self.tasks = tasks
        self.agents = agents
        self.artifacts = artifacts
        self.channelId = channelId
        self.showsOnlyInProgress = showsOnlyInProgress
        self.onArtifactOpen = onArtifactOpen
    }

    init(state: ChannelState, showsOnlyInProgress: Bool = false, onArtifactOpen: @escaping (ChannelArtifact) -> Void) {
        self.init(tasks: state.channel.tasks, agents: state.agents, artifacts: state.artifacts,
                  channelId: state.channel.id, showsOnlyInProgress: showsOnlyInProgress,
                  onArtifactOpen: onArtifactOpen)
    }

    /// The one filter rule, shared by every level. A kept task renders from its full value.
    static func keeps(_ task: ChannelTask, showsOnlyInProgress: Bool) -> Bool {
        !showsOnlyInProgress || task.holdsWorkInProgress
    }

    var body: some View {
        // Slots come from the whole list, so turning the filter on or off never moves a row's slot.
        let entries = slots.entries(tasks, in: channelId)
        let shown = entries.filter { OverviewTaskList.keeps($0.item, showsOnlyInProgress: showsOnlyInProgress) }
        Group {
            if tasks.isEmpty {
                OverviewEmptyText("No tasks yet")
            } else if shown.isEmpty {
                OverviewEmptyText("No tasks in progress")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { entry in
                        OverviewTaskRow(task: entry.item, key: entry.key, agents: agents, artifacts: artifacts,
                                        showsOnlyInProgress: showsOnlyInProgress, disclosure: $disclosure,
                                        onArtifactOpen: onArtifactOpen)
                    }
                }
            }
        }
        .onChange(of: channelId) { disclosure = .init() }
        .onChange(of: tasks) {
            disclosure.reconcile(slots.entries(tasks, in: channelId).map { ($0.key, $0.item) }) { "\($0)/\($1.id)" }
        }
    }
}

struct OverviewTaskRow: View {
    static let statusSize: CGFloat = 16
    static let titleGap: CGFloat = 6

    @Environment(\.channelTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.overviewTaskFocusInteractions) private var focusInteractions
    let task: ChannelTask
    /// Names the task for this visit to its channel, so its disclosure stays its own. See `OverviewSlots`.
    let key: String
    let agents: [ChannelAgent]
    let artifacts: [ChannelArtifact]
    /// Hides children without in-progress work. Progress and the diff still describe every child.
    let showsOnlyInProgress: Bool
    @Binding var disclosure: ChannelTask.Disclosure
    let onArtifactOpen: (ChannelArtifact) -> Void
    @ViewState private var isTimingVisible = false

    init(task: ChannelTask, key: String, agents: [ChannelAgent], artifacts: [ChannelArtifact],
         showsOnlyInProgress: Bool = false, disclosure: Binding<ChannelTask.Disclosure>,
         onArtifactOpen: @escaping (ChannelArtifact) -> Void) {
        self.task = task
        self.key = key
        self.agents = agents
        self.artifacts = artifacts
        self.showsOnlyInProgress = showsOnlyInProgress
        _disclosure = disclosure
        self.onArtifactOpen = onArtifactOpen
    }

    private var isExpanded: Bool { disclosure.isExpanded(task, key: key) }

    private var children: [ChannelTask] { task.children ?? [] }
    /// The children this row shows. Progress and the diff still count every child.
    private var visibleChildren: [ChannelTask] {
        children.filter { OverviewTaskList.keeps($0, showsOnlyInProgress: showsOnlyInProgress) }
    }
    private var owner: ChannelAgent? { task.ownerId.map { ChannelAgent(id: $0, in: agents) } }
    private var progress: (done: Int, total: Int)? {
        guard task.showsChildProgress else { return nil }
        let progress = children.progress
        return (progress.done, progress.total)
    }

    private var diff: DiffStats? { task.status == "pending" ? nil : [task].diff }
    private var linkedArtifact: (id: String, artifact: ChannelArtifact?)? {
        task.artifactId.map { id in (id, artifacts.first { $0.id == id }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            timedHeader
            if let linkedArtifact {
                artifactLink(linkedArtifact.artifact)
                    .padding(.leading, Self.statusSize + Self.titleGap)
                    .padding(.top, 4)
                    .padding(.bottom, 5)
            }
            if isExpanded, !visibleChildren.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleChildren) { child in
                        OverviewTaskRow(task: child, key: "\(key)/\(child.id)", agents: agents,
                                        artifacts: artifacts, showsOnlyInProgress: showsOnlyInProgress,
                                        disclosure: $disclosure, onArtifactOpen: onArtifactOpen)
                    }
                }
                .padding(.leading, OverviewTaskList.depthIndent)
                .overlay {
                    ChannelTaskAncestryGuide(statusWidth: Self.statusSize)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
    }

    @ViewBuilder
    private var timedHeader: some View {
        if task.startedAt.flatMap({ try? Date($0, strategy: .iso8601) }) != nil {
            TimelineView(ChannelTaskMinuteSchedule(isVisible: isTimingVisible)) { context in
                header(timing: task.timing(now: context.date))
            }
            .onScrollVisibilityChange(threshold: 0.01) { isTimingVisible = $0 }
        } else {
            header(timing: nil)
        }
    }

    private func header(timing: ChannelTask.Timing?) -> some View {
        HStack(alignment: .top, spacing: Self.titleGap) {
            OverviewTaskStatusIcon(status: task.status)
            VStack(alignment: .leading, spacing: ChannelOverviewFactsLayout.titleGap) {
                HStack(alignment: .top, spacing: 8) {
                    firstLine
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let owner {
                        AgentAvatarView(agent: owner, size: 16)
                            .help("Owned by \(owner.name)")
                    }
                }
                if timing != nil || diff != nil {
                    ChannelOverviewTaskMetadata(timing: timing, diff: diff)
                        .font(.system(size: 11 * textScale))
                }
            }
        }
        .padding(.top, 5)
        .padding(.bottom, linkedArtifact == nil ? 5 : 0)
        .contentShape(Rectangle())
        .onTapGesture { if !visibleChildren.isEmpty { toggle() } }
        .focusable(!visibleChildren.isEmpty, interactions: focusInteractions)
        .onKeyPress(.rightArrow) { setExpanded(true) }
        .onKeyPress(.leftArrow) { setExpanded(false) }
        .onKeyPress(.space) { setExpanded(!isExpanded) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(timing: timing))
        .modifier(OverviewTaskRowRole(isParent: !visibleChildren.isEmpty, isExpanded: isExpanded, toggle: toggle))
        .accessibilityActions {
            if let linkedArtifact, let artifact = linkedArtifact.artifact {
                Button("Open Artifact") { onArtifactOpen(artifact) }
            }
            if !visibleChildren.isEmpty {
                Button(isExpanded ? "Collapse" : "Expand", action: toggle)
            }
        }
    }

    /// The title, then an open parent's "3/4" and a parent's chevron, as one wrapping text.
    private var firstLine: Text {
        let title = Text(verbatim: task.title.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(size: 13 * textScale))
            .foregroundStyle(task.status == "done" ? Color.secondary : Color.primary)
        guard !children.isEmpty else { return title }
        return OverviewInlineDisclosure.line(title, isExpanded: isExpanded,
                                             count: progress.map { "\($0.done)/\($0.total)" },
                                             showsChevron: !visibleChildren.isEmpty, textScale: textScale)
    }

    private func artifactLink(_ artifact: ChannelArtifact?) -> some View {
        Button {
            if let artifact { onArtifactOpen(artifact) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "doc.text")
                    .accessibilityHidden(true)
                Text(artifact?.title ?? "Artifact unavailable")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12 * textScale))
            .foregroundStyle(artifact == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color(nsColor: .linkColor)))
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(artifact == nil)
        .accessibilityLabel(artifact.map { "Open \($0.title)" } ?? "Artifact unavailable")
        .help(artifact.map { "Open \($0.title)" } ?? "This artifact is no longer shared in the channel.")
    }

    private func toggle() {
        disclosure.set(!isExpanded, task, key: key)
    }

    private func setExpanded(_ expanded: Bool) -> KeyPress.Result {
        guard !visibleChildren.isEmpty else { return .ignored }
        if expanded != isExpanded { toggle() }
        return .handled
    }

    private func accessibilityLabel(timing: ChannelTask.Timing?) -> String {
        var parts = [task.title, task.statusDescription]
        if let timing { parts.append(timing.spoken) }
        if let progress {
            parts.append("\(progress.done) of \(progress.total) subtasks done")
        }
        if let diff { parts.append(ChannelOverviewTaskDiff.spoken(diff)) }
        if let owner { parts.append("owner \(owner.name)") }
        if let linkedArtifact {
            parts.append(linkedArtifact.artifact.map { "artifact \($0.title)" } ?? "artifact unavailable")
        }
        return parts.joined(separator: ", ")
    }
}


/// A parent row is a button whose press toggles it, as the routine rows are. A leaf is static text.
private struct OverviewTaskRowRole: ViewModifier {
    let isParent: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        if isParent {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityAction(.default, toggle)
        } else {
            content.accessibilityAddTraits(.isStaticText)
        }
    }
}

/// A read-only 16-point status cell, never a toggleable checkbox.
struct OverviewTaskStatusIcon: View {
    @Environment(\.channelTextScale) private var textScale
    let status: String

    var body: some View {
        ChannelTaskStatusSymbol(status: status)
            .font(.system(size: 14 * textScale))
            .frame(width: OverviewTaskRow.statusSize, height: OverviewTaskRow.statusSize)
    }
}
