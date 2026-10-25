import Foundation

/// Vertical document coordinates. Rows are supplied in conversation order, with increasing tops.
/// The container applies placements during layout and never reports those writes as reader input.
/// Use `layoutEvent` for real geometry changes, not each repeated native layout pass.
public enum TranscriptScrollModel {
    public typealias RowID = String

    public static let endClearance: CGFloat = 16
    public static let followingThreshold: CGFloat = 48

    public struct RowFrame: Equatable, Sendable {
        public let id: RowID
        public let order: Int
        public let top: CGFloat
        public let height: CGFloat
        /// Accessories contribute geometry but cannot be anchored, targeted, or marked read.
        public let isAnchorable: Bool
        public var bottom: CGFloat { top + height }

        public init(id: RowID, order: Int, top: CGFloat, height: CGFloat, isAnchorable: Bool = true) {
            precondition(!id.isEmpty && top.isFinite && height.isFinite && height >= 0 && (top + height).isFinite)
            self.id = id
            self.order = order
            self.top = top
            self.height = height
            self.isAnchorable = isAnchorable
        }
    }

    public struct Viewport: Equatable, Sendable {
        /// Row layout width, so width-only changes are distinct from repeated layout passes.
        public let width: CGFloat
        public let height: CGFloat
        public let topInset: CGFloat
        public let bottomInset: CGFloat
        public var unobscuredHeight: CGFloat { max(0, height - topInset - bottomInset) }

        public init(width: CGFloat, height: CGFloat, topInset: CGFloat, bottomInset: CGFloat) {
            precondition(width.isFinite && width >= 0 && height.isFinite && height >= 0
                         && topInset.isFinite && topInset >= 0
                         && bottomInset.isFinite && bottomInset >= 0)
            self.width = width
            self.height = height
            self.topInset = topInset
            self.bottomInset = bottomInset
        }
    }

    public struct Anchor: Equatable, Sendable {
        public let row: RowID
        public let order: Int
        public let offset: CGFloat

        public init(row: RowID, order: Int, offset: CGFloat) {
            precondition(!row.isEmpty && offset.isFinite)
            self.row = row
            self.order = order
            self.offset = offset
        }
    }

    public enum Target: Equatable, Sendable {
        case row(RowID, order: Int)
        case end
    }

    public enum Intent: Equatable, Sendable {
        case landing(Target)
        case following
        case reading(Anchor)
        case revealing(RowID, order: Int)
    }

    public enum Event: Equatable, Sendable {
        /// Only for changed row frames or viewport geometry. Use `layoutEvent` to suppress no-ops.
        case layoutChanged
        case readerScrolled(to: CGFloat)
        /// Captures reading without moving. With no anchorable rows, preserves the existing intent.
        case holdCurrentPosition
        case land(Target)
        case jumpToLatest
        case ownPostConfirmed
        case reveal(RowID)
        case toggledExpansion(RowID, expanded: Bool)
    }

    public struct Placement: Equatable, Sendable {
        public let intent: Intent
        /// Nil leaves the position to the reader. Animation and its cancellation belong to the adapter.
        public let origin: CGFloat?
        /// The adapter reports an unavailable explicit row action instead of silently moving elsewhere.
        public let unavailableTarget: RowID?

        public init(intent: Intent, origin: CGFloat?, unavailableTarget: RowID? = nil) {
            precondition(origin?.isFinite != false)
            self.intent = intent
            self.origin = origin
            self.unavailableTarget = unavailableTarget
        }
    }

    public static func reduce(_ intent: Intent, _ event: Event, rows: [RowFrame],
                              viewport: Viewport, origin: CGFloat) -> Placement {
        precondition(origin.isFinite)
        switch event {
        case .readerScrolled(let y):
            precondition(y.isFinite)
            let next: Intent
            if distanceToEnd(y, rows: rows, viewport: viewport) <= followingThreshold {
                next = .following
            } else if let anchor = readingAnchor(y, rows: rows, viewport: viewport) {
                next = .reading(anchor)
            } else {
                next = .following
            }
            return Placement(intent: next, origin: nil)
        case .holdCurrentPosition:
            let anchor = readingAnchor(origin, rows: rows, viewport: viewport)
            return Placement(intent: anchor.map(Intent.reading) ?? intent, origin: nil)
        case .land(let target):
            if case .row(let id, _) = target, anchorableRow(id, rows: rows) == nil {
                return Placement(intent: intent, origin: nil, unavailableTarget: id)
            }
            return place(.landing(target), rows: rows, viewport: viewport)
        case .jumpToLatest, .ownPostConfirmed:
            return place(.following, rows: rows, viewport: viewport)
        case .reveal(let id):
            guard let row = anchorableRow(id, rows: rows) else {
                return Placement(intent: intent, origin: nil, unavailableTarget: id)
            }
            return place(.revealing(id, order: row.order), rows: rows, viewport: viewport)
        case .toggledExpansion(let id, let expanded):
            guard let row = anchorableRow(id, rows: rows) else {
                return Placement(intent: intent, origin: nil, unavailableTarget: id)
            }
            let offset = row.top - origin - viewport.topInset
            let anchor = Anchor(row: row.id, order: row.order, offset: expanded ? offset : max(offset, 0))
            return place(.reading(anchor), rows: rows, viewport: viewport)
        case .layoutChanged:
            return place(intent, rows: rows, viewport: viewport)
        }
    }

    /// Repeated native layout passes and content-only changes must not undo a reader's position.
    public static func layoutEvent(from oldRows: [RowFrame], viewport oldViewport: Viewport,
                                   to rows: [RowFrame], viewport: Viewport) -> Event? {
        oldViewport != viewport || oldRows != rows ? .layoutChanged : nil
    }

    /// The sole end clearance. The container's document height is this value, without extra padding.
    public static func end(_ rows: [RowFrame]) -> CGFloat {
        (rows.last?.bottom ?? 0) + endClearance
    }

    public static func distanceToEnd(_ origin: CGFloat, rows: [RowFrame], viewport: Viewport) -> CGFloat {
        precondition(origin.isFinite)
        return max(0, end(rows) - origin - viewport.height + viewport.bottomInset)
    }

    /// Preserves read eligibility: at least 24 unobscured points, or half of a shorter row.
    public static func visibleRows(_ rows: [RowFrame], viewport: Viewport, origin: CGFloat) -> [RowID] {
        precondition(origin.isFinite)
        guard viewport.width > 0, viewport.unobscuredHeight > 0 else { return [] }
        let top = origin + viewport.topInset
        let bottom = origin + viewport.height - viewport.bottomInset
        return rows.compactMap { row in
            guard row.isAnchorable else { return nil }
            let visible = min(row.bottom, bottom) - max(row.top, top)
            return visible > 0 && visible >= min(24, row.height / 2) ? row.id : nil
        }
    }

    public static func firstRowStartingInView(_ origin: CGFloat, rows: [RowFrame],
                                             viewport: Viewport) -> Anchor? {
        precondition(origin.isFinite)
        guard viewport.width > 0, viewport.unobscuredHeight > 0 else { return nil }
        let top = origin + viewport.topInset
        let bottom = origin + viewport.height - viewport.bottomInset
        let starting = rows.first { $0.isAnchorable && $0.height > 0 && $0.top >= top && $0.top < bottom }
        let covering = rows.first { $0.isAnchorable && $0.top < top && $0.bottom > top }
        return (starting ?? covering).map { Anchor(row: $0.id, order: $0.order, offset: $0.top - top) }
    }

    private static func readingAnchor(_ origin: CGFloat, rows: [RowFrame], viewport: Viewport) -> Anchor? {
        if let anchor = firstRowStartingInView(origin, rows: rows, viewport: viewport) { return anchor }
        let top = origin + viewport.topInset
        // A gap with no visible row must not retain a landing/reveal intent and later undo input.
        let row = rows.first(where: { $0.isAnchorable && $0.top >= top }) ?? rows.last(where: \.isAnchorable)
        return row.map { Anchor(row: $0.id, order: $0.order, offset: $0.top - top) }
    }

    private static func place(_ intent: Intent, rows: [RowFrame], viewport: Viewport) -> Placement {
        let proposed: CGFloat
        switch intent {
        case .following, .landing(.end):
            proposed = end(rows) - viewport.height + viewport.bottomInset
        case .landing(.row(let id, let order)):
            guard let row = survivor(id: id, order: order, rows: rows) else {
                return place(.following, rows: rows, viewport: viewport)
            }
            proposed = row.top - viewport.topInset
        case .reading(let anchor):
            guard let row = survivor(id: anchor.row, order: anchor.order, rows: rows) else {
                return place(.following, rows: rows, viewport: viewport)
            }
            proposed = row.top - viewport.topInset - anchor.offset
        case .revealing(let id, let order):
            guard let row = survivor(id: id, order: order, rows: rows) else {
                return place(.following, rows: rows, viewport: viewport)
            }
            let middle = viewport.topInset + viewport.unobscuredHeight / 2
            proposed = row.top + row.height / 2 - middle
        }
        let minimum = -viewport.topInset
        let maximum = max(minimum, end(rows) - viewport.height + viewport.bottomInset)
        return Placement(intent: intent, origin: min(maximum, max(minimum, proposed)))
    }

    private static func survivor(id: RowID, order: Int, rows: [RowFrame]) -> RowFrame? {
        anchorableRow(id, rows: rows) ?? rows.first(where: { $0.isAnchorable && $0.order >= order })
            ?? rows.last(where: \.isAnchorable)
    }

    private static func anchorableRow(_ id: RowID, rows: [RowFrame]) -> RowFrame? {
        rows.first(where: { $0.isAnchorable && $0.id == id })
    }
}
