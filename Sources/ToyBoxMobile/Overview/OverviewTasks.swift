import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct OverviewTasksSection: View {
    let store: ChannelStore
    let session: OverviewSession

    var body: some View {
        let progress = channelTasksProgress(store.tasks)
        Section {
            if session.isExpanded(.tasks) {
                if store.tasks.isEmpty {
                    Text("No tasks yet").foregroundStyle(ChannelInk.secondary)
                } else {
                    ForEach(store.tasks) { task in
                        OverviewTaskTree(task: task, store: store, session: session)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .padding(.bottom, 8)
                    }
                }
            }
        } header: {
            OverviewSectionHeader(title: "Tasks", count: "\(progress.done)/\(progress.total)",
                                  section: .tasks, session: session, diff: channelTasksDiff(store.tasks))
                .accessibilityIdentifier("overview-tasks")
                .id("overview-tasks")
        }
    }
}

struct OverviewSubtasksScreen: View {
    let parentID: String
    let store: ChannelStore
    let session: OverviewSession
    let placement: OverviewPlacement
    @Bindable var scroll: OverviewTaskScroll
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(OverviewPresentation.self) private var presentation
    @Environment(ChannelInteraction.self) private var interaction

    var body: some View {
        Group {
            if let parent = session.task(parentID) {
                Form {
                    Section {
                        Text(parent.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if parent.showsChildProgress {
                            let progress = channelTasksProgress(parent.children ?? [])
                            Text("\(progress.done) of \(progress.total) subtasks done")
                                .font(.footnote).foregroundStyle(ChannelInk.secondary)
                        }
                    }
                    Section {
                        ForEach(parent.children ?? []) { task in
                            OverviewTaskTree(task: task, store: store, session: session)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .padding(.bottom, 8)
                        }
                    }
                }
                .accessibilityIdentifier("overview-subtasks-form-\(parentID)")
                .scrollPosition($scroll.position)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, offset in
                    if placement == presentation.placement, interaction.isInspectorPresented,
                       scroll.restorationOffset == nil { scroll.offset = offset }
                }
                .task {
                    await Task.yield()
                    if !Task.isCancelled, placement == presentation.placement { scroll.restore() }
                }
                .onDisappear { scroll.prepare() }
            } else {
                ContentUnavailableView("Task unavailable", systemImage: "checklist",
                                       description: Text("This task is no longer in the channel."))
            }
        }
        .navigationTitle("Subtasks")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: store.tasks, initial: true) { _, tasks in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { session.reconcileTasks(tasks) }
        }
    }
}

struct OverviewTaskReadingLayout {
    let contentWidth: CGFloat
    let statusWidth: CGFloat
    let titleGap: CGFloat
    let ownerWidth: CGFloat
    let scaledReadingWidth: CGFloat
    let accessibility: Bool
    let rootHasOwner: Bool

    var indent: CGFloat { min(32, statusWidth + titleGap) }
    var readingFloor: CGFloat { min(titleWidth(depth: 0, hasOwner: rootHasOwner), max(192, scaledReadingWidth)) }

    func titleWidth(depth: Int, hasOwner: Bool) -> CGFloat {
        max(0, contentWidth - CGFloat(depth) * indent
            - (accessibility ? 0 : statusWidth + titleGap + (hasOwner ? ownerWidth + 8 : 0)))
    }

    func canInlineChildren(ofDepth depth: Int, haveOwner: Bool) -> Bool {
        contentWidth > 0 && titleWidth(depth: depth + 1, hasOwner: haveOwner) >= readingFloor
    }
}

private struct OverviewTaskTree: View {
    let task: ChannelTask
    let store: ChannelStore
    let session: OverviewSession
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var statusWidth = 16
    @ScaledMetric(relativeTo: .body) private var titleGap = 6
    @ScaledMetric(relativeTo: .body) private var ownerWidth = 20
    @ScaledMetric(relativeTo: .body) private var readingWidth = 192
    @ViewState private var width: CGFloat = 0

    var body: some View {
        let layout = OverviewTaskReadingLayout(
            contentWidth: width, statusWidth: min(24, statusWidth), titleGap: min(8, titleGap),
            ownerWidth: min(28, ownerWidth), scaledReadingWidth: readingWidth,
            accessibility: typeSize.isAccessibilitySize, rootHasOwner: task.ownerId != nil)
        OverviewTaskNode(task: task, store: store, session: session, depth: 0, layout: layout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

private struct OverviewTaskNode: View {
    let task: ChannelTask
    let store: ChannelStore
    let session: OverviewSession
    let depth: Int
    let layout: OverviewTaskReadingLayout
    @Environment(ChannelArtifactSession.self) private var viewer
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @ViewState private var isVisible = false

    private var children: [ChannelTask] { task.children ?? [] }
    private var expanded: Bool {
        guard let saved = session.taskDisclosure[task.id], saved.status == task.status else {
            return task.isExpandedByDefault
        }
        return saved.expanded
    }
    private var owner: ChannelAgent? { task.ownerId.map { channelAgentIdentity(store.roster, id: $0) } }
    private var diff: DiffStats? { task.status == "pending" ? nil : channelTasksDiff([task]) }
    private var artifact: ChannelArtifact? { store.artifacts.first { $0.id == task.artifactId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            timedHeader
                .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
                .onDisappear { isVisible = false }
            if task.artifactId != nil {
                Button {
                    if let artifact { viewer.open(artifact) }
                } label: {
                    Label(artifact?.title ?? "Artifact unavailable", systemImage: "doc.text")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.borderless)
                .disabled(artifact == nil)
                .padding(.leading, layout.accessibility ? 0 : layout.statusWidth + layout.titleGap)
                .accessibilityLabel(artifact.map { "Open \($0.title)" } ?? "Artifact unavailable")
                .accessibilityIdentifier("overview-task-artifact-\(task.id)")
            }
            if expanded, !children.isEmpty {
                if layout.canInlineChildren(ofDepth: depth, haveOwner: children.contains { $0.ownerId != nil }) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(children) {
                            OverviewTaskNode(task: $0, store: store, session: session, depth: depth + 1, layout: layout)
                        }
                    }
                    .padding(.leading, layout.indent)
                } else {
                    NavigationLink(value: OverviewRoute.subtasks(task.id)) {
                        HStack {
                            Text("View \(children.count) subtasks")
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }
                        .font(.body)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, layout.accessibility ? 0 : layout.statusWidth + layout.titleGap)
                    .accessibilityLabel("View \(children.count) subtasks of \(task.title)")
                    .accessibilityIdentifier("overview-subtasks-\(task.id)")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var timedHeader: some View {
        if task.startedAt.flatMap(ChannelDates.date) != nil {
            TimelineView(ChannelTaskMinuteSchedule(isVisible: isVisible)) { context in
                header(timing: channelTaskTiming(task, now: context.date))
            }
        } else {
            header(timing: nil)
        }
    }

    private func header(timing: ChannelTaskTiming?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if layout.accessibility {
                HStack {
                    if children.isEmpty {
                        status
                        Spacer(minLength: 8)
                    } else {
                        Button(action: toggle) {
                            HStack { status; Spacer(minLength: 0) }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                    }
                    ownerAvatar
                }
                .frame(minHeight: 44)
            }
            HStack(alignment: .top, spacing: 8) {
                if children.isEmpty {
                    heading(timing: timing)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(spoken(timing: timing))
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityIdentifier("overview-task-\(task.id)")
                } else {
                    Button(action: toggle) { heading(timing: timing) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(spoken(timing: timing))
                        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                        .accessibilityActions {
                            Button(expanded ? "Collapse" : "Expand", action: toggle)
                        }
                        .accessibilityIdentifier("overview-task-\(task.id)")
                }
                if !layout.accessibility { ownerAvatar.padding(.top, 12) }
            }
        }
    }

    private func heading(timing: ChannelTaskTiming?) -> some View {
        HStack(alignment: .top, spacing: layout.titleGap) {
            if !layout.accessibility { status.padding(.top, 2) }
            VStack(alignment: .leading, spacing: 3) {
                firstLine.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if timing != nil || diff != nil {
                    OverviewMetadataLayout(direction: layoutDirection) {
                        if let timing {
                            let presentation = ChannelTaskTimingPresentation(timing: timing)
                            Label(presentation.elapsedText, systemImage: "clock")
                            if let remaining = presentation.checkInText {
                                Label(remaining, systemImage: "bell")
                            }
                        }
                        if let diff {
                            let colors = ChannelTaskColors.changes(in: colorScheme)
                            Text("+\(diff.added.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))")
                                .foregroundStyle(colors.added)
                            Text("\u{2212}\(diff.removed.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))")
                                .foregroundStyle(colors.removed)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(ChannelInk.secondary)
                    .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var firstLine: Text {
        let title = Text(verbatim: task.title).font(.body)
            .foregroundStyle(task.status == "done" ? ChannelInk.secondary : .primary)
        guard !children.isEmpty else { return title }
        let gap = Text(verbatim: "\u{00A0}\u{00A0}")
        let progress: Text
        if task.showsChildProgress {
            let count = channelTasksProgress(children)
            progress = Text(verbatim: "\(count.done)/\(count.total)\u{00A0}")
                .font(.footnote.monospacedDigit()).foregroundStyle(ChannelInk.secondary)
        } else { progress = Text(verbatim: "") }
        return title + gap + progress
            + Text(Image(systemName: expanded ? "chevron.down" : "chevron.right"))
                .font(.footnote.weight(.semibold)).foregroundStyle(ChannelInk.secondary)
    }

    @ViewBuilder
    private var ownerAvatar: some View {
        if let owner {
            AgentAvatarView(agent: owner, size: layout.ownerWidth)
                .accessibilityHidden(true)
        }
    }

    private var status: some View {
        Image(systemName: task.status == "done" ? "checkmark.circle.fill"
              : task.status == "blocked" ? "exclamationmark.circle.fill"
              : task.status == "in_progress" ? "circle.lefthalf.filled" : "circle")
            .symbolRenderingMode(task.status == "blocked" ? .palette : .monochrome)
            .foregroundStyle(task.status == "blocked" ? Color.white
                             : task.status == "done" ? ChannelTaskColors.changes(in: colorScheme).added
                             : ChannelInk.secondary, Color.red)
            .font(.system(size: layout.statusWidth * 0.875,
                          weight: task.status == "done" || task.status == "blocked" ? .semibold : .regular))
            .frame(width: layout.statusWidth, height: layout.statusWidth)
            .accessibilityHidden(true)
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            session.taskDisclosure[task.id] = .init(status: task.status, expanded: !expanded)
        }
    }

    private func spoken(timing: ChannelTaskTiming?) -> String {
        var parts = [task.title, task.statusDescription]
        if task.showsChildProgress {
            let progress = channelTasksProgress(children)
            parts.append("\(progress.done) of \(progress.total) subtasks done")
        }
        if let timing { parts.append(ChannelTaskTimingPresentation(timing: timing).spoken) }
        if let diff { parts.append("\(diff.added) additions, \(diff.removed) deletions") }
        if let owner { parts.append("owner \(owner.name)") }
        return parts.joined(separator: ", ")
    }
}

private struct OverviewMetadataLayout: Layout {
    let direction: LayoutDirection
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = layout.frames[index]
            let x = direction == .rightToLeft
                ? bounds.maxX - frame.maxX : bounds.minX + frame.minX
            subview.place(at: CGPoint(x: x,
                                      y: bounds.minY + frame.minY),
                          proposal: .init(width: frame.width, height: frame.height))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, measuredWidth: CGFloat = 0
        var frames: [CGRect] = []
        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(.init(width: min(natural.width, max(0, width)), height: nil))
            if x > 0, x + size.width > width { x = 0; y += height + 3; height = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            measuredWidth = max(measuredWidth, x + size.width)
            x += size.width + 10
            height = max(height, size.height)
        }
        return (CGSize(width: measuredWidth, height: y + height), frames)
    }
}

struct OverviewTaskDiff: View {
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
