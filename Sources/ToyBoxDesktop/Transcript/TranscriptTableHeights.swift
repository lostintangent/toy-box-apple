import AppKit
import ChannelClient
import ChannelKit
import SwiftUI
import Synchronization

struct TranscriptTableItem: Identifiable, Equatable {
    let row: TranscriptRow
    let canonicalRowID: String
    let showsAvatar: Bool
    let topSpacing: CGFloat
    let order: Int

    var id: String { row.id }

    static func project(_ rows: [TranscriptRow]) -> [Self] {
        let stacked = transcriptStackedSystemRowIDs(rows)
        return rows.flatMap { row in
            if case .agent(let agentID, let entries) = row.content {
                return entries.enumerated().map { index, entry in
                    var cell = row
                    cell.id = entry.id
                    cell.content = .agent(agentId: agentID, entries: [entry])
                    if index != 0 { cell.divider = nil }
                    return Self(row: cell, canonicalRowID: row.id, showsAvatar: index == 0,
                                topSpacing: index == 0 ? 20 : 8, order: entry.message.sequence)
                }
            }
            return [Self(row: row, canonicalRowID: row.id, showsAvatar: true,
                         topSpacing: stacked.contains(row.id) ? 4 : 20, order: row.messages.first?.sequence ?? 0)]
        }
    }
}

private struct TranscriptTableCoordinationOverflowKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var transcriptTableCoordinationOverflow: Bool? {
        get { self[TranscriptTableCoordinationOverflowKey.self] }
        set { self[TranscriptTableCoordinationOverflowKey.self] = newValue }
    }
}

@MainActor
final class TranscriptTableHeights {
    struct Result {
        let heights: [CGFloat]
        let overflows: [Bool?]
        let measured: Int
        let exactIndexes: IndexSet
    }

    struct Environment: Equatable {
        let width: CGFloat
        let textScale: CGFloat
        let displayScale: CGFloat
        let dynamicTypeSize: DynamicTypeSize
        let direction: LayoutDirection
        let locale: Locale
        let controlSize: ControlSize
        let font: Font?
        let legibility: LegibilityWeight?

        init(width: CGFloat, values: EnvironmentValues) {
            self.width = width
            textScale = values.channelTextScale
            displayScale = values.displayScale
            dynamicTypeSize = values.dynamicTypeSize
            direction = values.layoutDirection
            locale = values.locale
            controlSize = values.controlSize
            font = values.font
            legibility = values.legibilityWeight
        }
    }

    private struct Entry {
        let item: TranscriptTableItem
        let content: TranscriptRowContent
        let environment: Environment
        let catchUpPhase: TranscriptCatchUp.Phase?
        let height: CGFloat
        let overflows: Bool?
    }

    @MainActor private struct Resolution {
        let items: [TranscriptTableItem]
        let content: [TranscriptRowContent]
        let environment: Environment
        let summaries: [(summary: TranscriptCatchUp, phase: TranscriptCatchUp.Phase)]
        let result: Result

        func matches(items: [TranscriptTableItem], content: [TranscriptRowContent],
                     environment: Environment) -> Bool {
            self.environment == environment && self.items == items && self.content == content
                && summaries.allSatisfy { $0.summary.phase == $0.phase }
        }
    }

    private var entries: [String: [Entry]] = [:]
    private var resolution: Resolution?
    private let sizer = TranscriptTableSizer()
    private(set) var measurementCount = 0
    private(set) var identityCheckCount = 0

    func measureAccessory(_ view: AnyView, width: CGFloat, environment: EnvironmentValues) -> CGFloat {
        sizer.measure([view], width: width, environment: environment)[0]
    }

    func recordLiveHeight(_ height: CGFloat, item: TranscriptTableItem, content: TranscriptRowContent,
                          width: CGFloat, environment: EnvironmentValues, overflows: Bool?) {
        precondition(height.isFinite && height > 0 && width.isFinite && width > 0)
        let metrics = Environment(width: width, values: environment)
        resolution = nil
        store(height: height, item: item, content: content, metrics: metrics, overflows: overflows)
    }

    func resolve(items: [TranscriptTableItem], content: [TranscriptRowContent], width: CGFloat,
                 environment: EnvironmentValues, measuring requested: IndexSet? = nil) -> Result {
        precondition(width.isFinite && width > 0 && items.count == content.count)
        precondition(requested?.allSatisfy { items.indices.contains($0) } ?? true)
        let metrics = Environment(width: width, values: environment)
        var heights: [CGFloat]
        var overflows: [Bool?]
        var exact: IndexSet
        let missing: [Int]
        if let resolution, resolution.matches(items: items, content: content, environment: metrics) {
            heights = resolution.result.heights
            overflows = resolution.result.overflows
            exact = resolution.result.exactIndexes
            missing = Array((requested ?? IndexSet(items.indices)).subtracting(exact))
            if missing.isEmpty {
                return Result(heights: heights, overflows: overflows, measured: 0, exactIndexes: exact)
            }
        } else {
            heights = [CGFloat](repeating: 100 * metrics.textScale, count: items.count)
            overflows = [Bool?](repeating: nil, count: items.count)
            exact = IndexSet()
            var requestedMissing: [Int] = []
            identityCheckCount += items.count
            for index in items.indices {
                let item = items[index]
                let row = sizingIdentity(content[index])
                if let cached = entries[item.id]?.first(where: {
                    $0.item.row == item.row && $0.item.showsAvatar == item.showsAvatar
                        && $0.item.topSpacing == item.topSpacing && $0.content == row && $0.environment == metrics
                        && $0.catchUpPhase == row.catchUp?.phase
                }) {
                    heights[index] = cached.height
                    overflows[index] = cached.overflows
                    exact.insert(index)
                } else {
                    if let previous = entries[item.id]?.first { heights[index] = previous.height }
                    if requested?.contains(index) != false { requestedMissing.append(index) }
                }
            }
            missing = requestedMissing
            let retained = Set(items.map(\.id))
            entries = entries.filter { retained.contains($0.key) }
        }
        let coordination = missing.filter { index in
            if case .agent(_, let entries) = items[index].row.content {
                return entries.first?.collapsible == true && entries.first?.body.isEmpty == false
            }
            return false
        }
        if !coordination.isEmpty {
            let markdown = coordination.map { index -> AnyView in
                guard case .agent(_, let entries) = items[index].row.content, let entry = entries.first else {
                    preconditionFailure("A coordination measurement needs its canonical agent entry.")
                }
                let row = content[index]
                let bodyWidth = max(1, min(width - ConversationRail.inset * 2 - 44,
                                           TranscriptWidthCap.agentSurface * metrics.textScale) - 24)
                return AnyView(TranscriptMarkdown(content: entry.body, agents: row.context.agents,
                                                   baseURL: row.context.api.baseURL)
                    .frame(width: bodyWidth)
                    .fixedSize(horizontal: false, vertical: true))
            }
            let measured = sizer.measure(markdown, width: width, environment: environment)
            for (offset, index) in coordination.enumerated() { overflows[index] = measured[offset] > 160 }
        }
        if !missing.isEmpty {
            let views = missing.map { index in
                AnyView(content[index]
                    .environment(\.transcriptTableCoordinationOverflow, overflows[index])
                    .padding(.top, items[index].topSpacing)
                    .modifier(ConversationRail()))
            }
            let measured = sizer.measure(views, width: width, environment: environment)
            for (offset, index) in missing.enumerated() {
                let height = ceil(measured[offset] * metrics.displayScale) / metrics.displayScale
                precondition(height.isFinite && height > 0, "A transcript table item must have an exact positive height.")
                heights[index] = height
                exact.insert(index)
                let item = items[index]
                store(height: height, item: item, content: content[index], metrics: metrics,
                      overflows: overflows[index])
            }
            measurementCount += missing.count
        }
        let result = Result(heights: heights, overflows: overflows, measured: missing.count, exactIndexes: exact)
        resolution = Resolution(items: items, content: content, environment: metrics,
                                summaries: content.compactMap { $0.catchUp.map { ($0, $0.phase) } }, result: result)
        return result
    }

    private func store(height: CGFloat, item: TranscriptTableItem, content: TranscriptRowContent,
                       metrics: Environment, overflows: Bool?) {
        let row = sizingIdentity(content)
        let entry = Entry(item: item, content: row, environment: metrics, catchUpPhase: row.catchUp?.phase,
                          height: height, overflows: overflows)
        var cached = entries[item.id, default: []]
        cached.removeAll { $0.item == item && $0.content == row && $0.environment == metrics
            && $0.catchUpPhase == row.catchUp?.phase }
        cached.insert(entry, at: 0)
        entries[item.id] = Array(cached.prefix(4))
    }

    private func sizingIdentity(_ content: TranscriptRowContent) -> TranscriptRowContent {
        var context = content.context
        context.historyStart = 0
        return TranscriptRowContent(row: content.row, context: context, statusReactions: content.statusReactions,
                                    highlightedSequence: content.highlightedSequence, catchUp: content.catchUp,
                                    store: content.store, expandedMessageIds: content.expandedMessageIds,
                                    findHighlights: content.findHighlights, showsAgentAvatar: content.showsAgentAvatar,
                                    onSetExpanded: content.onSetExpanded)
    }
}

@MainActor
private final class TranscriptTableSizer {
    private let controller = NSHostingController(rootView: AnyView(EmptyView()))

    init() {
        controller.sizingOptions = []
        controller.safeAreaRegions = []
    }

    func measure(_ views: [AnyView], width: CGFloat, environment: EnvironmentValues) -> [CGFloat] {
        let output = TranscriptTableSizingOutput()
        controller.rootView = AnyView(
            TranscriptTableSizingLayout(output: output) {
                ForEach(views.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 0) { views[index] }
                }
            }
            .environment(\.self, environment)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
        _ = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let result = output.measurements.withLock { $0 }
        precondition(result.width == width && result.heights.count == views.count,
                     "The sizing pass must measure every item at the table's exact width.")
        controller.rootView = AnyView(EmptyView())
        _ = controller.sizeThatFits(in: .zero)
        return result.heights
    }
}

private final class TranscriptTableSizingOutput: Sendable {
    struct Measurements {
        var width: CGFloat = 0
        var heights: [CGFloat] = []
    }
    let measurements = Mutex(Measurements())
}

private struct TranscriptTableSizingLayout: Layout {
    let output: TranscriptTableSizingOutput

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        output.measurements.withLock { $0 = .init(width: width, heights: heights) }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}
