import AppKit
import ChannelKit
import SwiftUI

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
    @ViewState private var slots = OverviewSlots()

    init(tasks: [ChannelTask], agents: [ChannelAgent], artifacts: [ChannelArtifact], channelId: String = "",
         onArtifactOpen: @escaping (ChannelArtifact) -> Void) {
        self.tasks = tasks
        self.agents = agents
        self.artifacts = artifacts
        self.channelId = channelId
        self.onArtifactOpen = onArtifactOpen
    }

    init(state: ChannelState, onArtifactOpen: @escaping (ChannelArtifact) -> Void) {
        self.init(tasks: state.channel.tasks, agents: state.agents, artifacts: state.artifacts,
                  channelId: state.channel.id, onArtifactOpen: onArtifactOpen)
    }

    var body: some View {
        Group {
            if tasks.isEmpty {
                OverviewEmptyText("No tasks yet")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slots.entries(tasks, in: channelId)) { entry in
                        OverviewTaskRow(task: entry.item, key: entry.key, agents: agents, artifacts: artifacts,
                                        onArtifactOpen: onArtifactOpen)
                    }
                }
            }
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
    let onArtifactOpen: (ChannelArtifact) -> Void
    @ViewState private var disclosure: OverviewItemState<Bool?>
    @ViewState private var isTimingVisible = false

    init(task: ChannelTask, key: String, agents: [ChannelAgent], artifacts: [ChannelArtifact],
         onArtifactOpen: @escaping (ChannelArtifact) -> Void) {
        self.task = task
        self.key = key
        self.agents = agents
        self.artifacts = artifacts
        self.onArtifactOpen = onArtifactOpen
        var disclosure = OverviewItemState<Bool?>(nil)
        disclosure[key] = Self.isExpandedByDefault(status: task.status)
        _disclosure = ViewState(initialValue: disclosure)
    }

    /// As in the pane's checklist, finished work folds down and everything else stays open.
    static func isExpandedByDefault(status: String) -> Bool { status != "done" }

    /// A row handed another task shows its default until the key change stores it.
    private var isExpanded: Bool { disclosure[key] ?? Self.isExpandedByDefault(status: task.status) }

    private var children: [ChannelTask] { task.children ?? [] }
    private var owner: ChannelAgent? { task.ownerId.map { channelAgentIdentity(agents, id: $0) } }
    private var progress: (done: Int, total: Int)? {
        guard Self.showsProgress(status: task.status, hasChildren: !children.isEmpty) else { return nil }
        let progress = channelTasksProgress(children)
        return (progress.done, progress.total)
    }

    /// Only open parents count their children. A done parent's are all done, and a pending one hasn't started.
    static func showsProgress(status: String, hasChildren: Bool) -> Bool {
        hasChildren && status != "pending" && status != "done"
    }
    private var diff: DiffStats? { task.status == "pending" ? nil : channelTasksDiff([task]) }
    private var linkedArtifact: (id: String, artifact: ChannelArtifact?)? {
        task.artifactId.map { id in (id, artifacts.first { $0.id == id }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            timedHeader
            if isExpanded, !children.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(children) { child in
                        OverviewTaskRow(task: child, key: "\(key)/\(child.id)", agents: agents,
                                        artifacts: artifacts, onArtifactOpen: onArtifactOpen)
                    }
                }
                .padding(.leading, OverviewTaskList.depthIndent)
            }
        }
        .accessibilityElement(children: .contain)
        // A status change re-derives the disclosure, replacing any manual toggle, as the pane does.
        .onChange(of: task.status) { _, status in
            let expanded = Self.isExpandedByDefault(status: status)
            guard expanded != isExpanded else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { disclosure[key] = expanded }
        }
        // A parent stores its default for the task it now shows, so that task's first status change
        // animates from it too. A leaf's disclosure shows nothing.
        .onChange(of: key) {
            guard !children.isEmpty else { return }
            disclosure[key] = Self.isExpandedByDefault(status: task.status)
        }
    }

    @ViewBuilder
    private var timedHeader: some View {
        if task.startedAt.flatMap(ChannelDates.date) != nil {
            TimelineView(OverviewTaskMinuteSchedule(isVisible: isTimingVisible)) { context in
                header(timing: channelTaskTiming(task, now: context.date))
            }
            .onScrollVisibilityChange(threshold: 0.01) { isTimingVisible = $0 }
        } else {
            header(timing: nil)
        }
    }

    private func header(timing: ChannelTaskTiming?) -> some View {
        HStack(alignment: .top, spacing: Self.titleGap) {
            OverviewTaskStatusIcon(status: task.status)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 8) {
                    firstLine
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let owner {
                        AgentAvatarView(agent: owner, size: 16)
                            .help("Owned by \(owner.name)")
                    }
                }
                if let timing {
                    let presentation = OverviewTaskTimingPresentation(timing: timing)
                    HStack(spacing: 10) {
                        Label(presentation.elapsedText, systemImage: "clock")
                            .help(presentation.elapsedHelp)
                        if let checkIn = presentation.checkInText {
                            Label(checkIn, systemImage: "bell")
                                .help(presentation.checkInHelp ?? "")
                        }
                    }
                    .font(.system(size: 11 * textScale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if diff != nil || linkedArtifact != nil {
                    metadata
                }
            }
        }
        .padding(.vertical, 5)
        // The whole parent row is the disclosure target. Its artifact link keeps its own action.
        .contentShape(Rectangle())
        .onTapGesture { if !children.isEmpty { toggle() } }
        .focusable(!children.isEmpty, interactions: focusInteractions)
        .onKeyPress(.rightArrow) { setExpanded(true) }
        .onKeyPress(.leftArrow) { setExpanded(false) }
        .onKeyPress(.space) { setExpanded(!isExpanded) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(timing: timing))
        .modifier(OverviewTaskRowRole(isParent: !children.isEmpty, isExpanded: isExpanded, toggle: toggle))
        .accessibilityActions {
            if let linkedArtifact, let artifact = linkedArtifact.artifact {
                Button("Open Artifact") { onArtifactOpen(artifact) }
            }
            if !children.isEmpty {
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
                                             textScale: textScale)
    }

    private var metadata: some View {
        HStack(spacing: 10) {
            if let diff { OverviewTaskDiff(diff: diff) }
            if let linkedArtifact { artifactLink(linkedArtifact.artifact) }
        }
        .lineLimit(1)
    }

    private func artifactLink(_ artifact: ChannelArtifact?) -> some View {
        Button {
            if let artifact { onArtifactOpen(artifact) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "doc.text")
                Text(artifact?.title ?? "Artifact unavailable").truncationMode(.tail)
            }
            .font(.system(size: 11 * textScale))
            .foregroundStyle(artifact == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color(nsColor: .linkColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(artifact == nil)
        .help(artifact.map { "Open \($0.title)" } ?? "This artifact is no longer shared in the channel.")
    }

    private func toggle() {
        let expanded = !isExpanded
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { disclosure[key] = expanded }
    }

    private func setExpanded(_ expanded: Bool) -> KeyPress.Result {
        guard !children.isEmpty else { return .ignored }
        if expanded != isExpanded { toggle() }
        return .handled
    }

    private func accessibilityLabel(timing: ChannelTaskTiming?) -> String {
        var parts = [task.title, OverviewTaskStatusIcon.spoken(task.status)]
        if let timing { parts.append(OverviewTaskTimingPresentation(timing: timing).spoken) }
        if let progress {
            parts.append("\(progress.done) of \(progress.total) subtasks done")
        }
        if let diff { parts.append(OverviewTaskDiff.spoken(diff)) }
        if let owner { parts.append("owner \(owner.name)") }
        if let linkedArtifact {
            parts.append(linkedArtifact.artifact.map { "artifact \($0.title)" } ?? "artifact unavailable")
        }
        return parts.joined(separator: ", ")
    }
}

struct OverviewTaskMinuteSchedule: TimelineSchedule {
    let isVisible: Bool

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        isVisible
            ? AnySequence(EveryMinuteTimelineSchedule().entries(from: startDate, mode: mode))
            : AnySequence([startDate])
    }
}

struct OverviewTaskTimingPresentation {
    let timing: ChannelTaskTiming

    var elapsedText: String { Self.duration(timing.elapsedMinutes) }
    var checkInText: String? { timing.checkInMinutes.map { Self.duration($0) } }
    var elapsedHelp: String { "Elapsed: \(Self.duration(timing.elapsedMinutes, spoken: true))" }
    var checkInHelp: String? {
        timing.checkInMinutes.map {
            $0 == 0 ? "Check-in due" : "Check-in in \(Self.duration($0, spoken: true))"
        }
    }

    var spoken: String {
        let elapsed = "\(Self.duration(timing.elapsedMinutes, spoken: true)) elapsed"
        guard let remaining = timing.checkInMinutes else { return elapsed }
        return elapsed + (remaining == 0 ? ", check-in due" : ", check-in in \(Self.duration(remaining, spoken: true))")
    }

    private static func duration(_ minutes: Int, spoken: Bool = false) -> String {
        let hours = minutes / 60, remainder = minutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append(spoken ? "\(hours) \(hours == 1 ? "hour" : "hours")" : "\(hours)h") }
        if remainder > 0 || hours == 0 {
            parts.append(spoken ? "\(remainder) \(remainder == 1 ? "minute" : "minutes")" : "\(remainder)m")
        }
        return parts.joined(separator: " ")
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
    @Environment(\.colorScheme) private var colorScheme
    let status: String

    static func spoken(_ status: String) -> String {
        switch status {
        case "in_progress": "in progress"
        case "done": "done"
        case "blocked": "blocked"
        default: "pending"
        }
    }

    var body: some View {
        icon
            .font(.system(size: 14 * textScale))
            .frame(width: OverviewTaskRow.statusSize, height: OverviewTaskRow.statusSize)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case "done":
            // Monochrome knocks the check out to the inspector, which a white check on green can't match.
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.monochrome)
                .fontWeight(.semibold)
                .foregroundStyle(ChannelTaskColors.changes(in: colorScheme).added)
        case "blocked":
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette)
                .fontWeight(.semibold)
                .foregroundStyle(.white, .red)
        case "in_progress":
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
        default:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

/// "+1.5K −114" in the adaptive change tokens. A measured zero still reads "+0 −0".
struct OverviewTaskDiff: View {
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    let diff: DiffStats

    var body: some View {
        let colors = ChannelTaskColors.changes(in: colorScheme)
        HStack(spacing: 4) {
            Text("+\(Self.compact(diff.added))").foregroundStyle(colors.added)
            Text("\u{2212}\(Self.compact(diff.removed))").foregroundStyle(colors.removed)
        }
        .font(.system(size: 11 * textScale, weight: .medium).monospacedDigit())
        .fixedSize()
        .help(Self.spoken(diff).prefix(1).uppercased() + Self.spoken(diff).dropFirst())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(diff))
    }

    static func spoken(_ diff: DiffStats) -> String {
        let added = diff.added.formatted()
        let removed = diff.removed.formatted()
        return "\(added) \(diff.added == 1 ? "addition" : "additions"), \(removed) \(diff.removed == 1 ? "deletion" : "deletions")"
    }

    static func compact(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
