import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct OverviewTaskListRow: Identifiable {
    enum ID: Hashable {
        case task(String), subtasks(String)
    }

    struct Guide: Identifiable, Equatable {
        let depth: Int
        let isFirst: Bool
        let isLast: Bool

        var id: Int { depth }
        var topClearance: CGFloat { isFirst ? 4 : 0 }
        var bottomClearance: CGFloat { isLast ? 4 : 0 }
    }

    let task: ChannelTask
    let depth: Int
    let layout: OverviewTaskReadingLayout
    var isSubtasks = false
    var guides: [Guide] = []
    var endsRoot = false

    var id: ID { isSubtasks ? .subtasks(task.id) : .task(task.id) }

    static func isExpanded(_ task: ChannelTask, disclosure: [String: OverviewSession.Disclosure]) -> Bool {
        guard let saved = disclosure[task.id], saved.status == task.status else {
            return task.isExpandedByDefault
        }
        return saved.expanded
    }

    static func visibleRows(
        tasks: [ChannelTask], disclosure: [String: OverviewSession.Disclosure],
        layout: (ChannelTask) -> OverviewTaskReadingLayout
    ) -> [Self] {
        var rows: [Self] = []
        func append(_ task: ChannelTask, depth: Int, layout: OverviewTaskReadingLayout) {
            rows.append(.init(task: task, depth: depth, layout: layout))
            let children = task.children ?? []
            guard !children.isEmpty, isExpanded(task, disclosure: disclosure) else { return }
            guard layout.canInlineChildren(ofDepth: depth, haveOwner: children.contains { $0.ownerId != nil }) else {
                rows.append(.init(task: task, depth: depth, layout: layout, isSubtasks: true))
                return
            }
            let first = rows.count
            for child in children { append(child, depth: depth + 1, layout: layout) }
            let last = rows.count - 1
            for index in first...last {
                rows[index].guides.append(.init(depth: depth, isFirst: index == first, isLast: index == last))
            }
        }
        for task in tasks {
            append(task, depth: 0, layout: layout(task))
            rows[rows.count - 1].endsRoot = true
        }
        return rows
    }
}

struct OverviewTaskRows: View {
    let tasks: [ChannelTask]
    let store: ChannelStore
    let session: OverviewSession
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var statusWidth = 16
    @ScaledMetric(relativeTo: .body) private var titleGap = 6
    @ScaledMetric(relativeTo: .body) private var ownerWidth = 20
    @ScaledMetric(relativeTo: .body) private var readingWidth = 192
    @ViewState private var width: CGFloat = 0

    var body: some View {
        let rows = OverviewTaskListRow.visibleRows(tasks: tasks, disclosure: session.taskDisclosure) { root in
            OverviewTaskReadingLayout(
                contentWidth: width, statusWidth: min(24, statusWidth), titleGap: min(8, titleGap),
                ownerWidth: min(28, ownerWidth), scaledReadingWidth: readingWidth,
                accessibility: typeSize.isAccessibilitySize, rootHasOwner: root.ownerId != nil)
        }
        ForEach(rows) { row in
            rowContent(row)
                .padding(.leading, CGFloat(row.depth) * row.layout.indent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    ForEach(row.guides) { guide in
                        ChannelTaskAncestryGuide(
                            statusWidth: row.layout.statusWidth,
                            topClearance: guide.topClearance, bottomClearance: guide.bottomClearance)
                            .padding(.leading, CGFloat(guide.depth) * row.layout.indent)
                    }
                }
                .padding(.bottom, row.endsRoot ? 8 : 0)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
                .listRowSeparator(.hidden)
                .transition(.identity)
        }
    }

    @ViewBuilder
    private func rowContent(_ row: OverviewTaskListRow) -> some View {
        if row.isSubtasks {
            NavigationLink(value: OverviewRoute.subtasks(row.task.id)) {
                HStack {
                    Text("View \((row.task.children ?? []).count) subtasks")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
                .font(.body)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .navigationLinkIndicatorVisibility(.hidden)
            .buttonStyle(.plain)
            .padding(.leading, row.layout.accessibility ? 0 : row.layout.statusWidth + row.layout.titleGap)
            .accessibilityLabel("View \((row.task.children ?? []).count) subtasks of \(row.task.title)")
            .accessibilityIdentifier("overview-subtasks-\(row.task.id)")
        } else {
            OverviewTaskNode(task: row.task, store: store, session: session, depth: row.depth, layout: row.layout)
        }
    }
}
