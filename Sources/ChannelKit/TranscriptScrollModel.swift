import Foundation

/// Vertical document coordinates. Rows are supplied in conversation order, with increasing tops.
/// The container applies placements during layout and never reports those writes as reader input.
/// Use `layoutEvent` for real geometry changes, not each repeated native layout pass.
public enum TranscriptScrollModel {
    public typealias RowID = String

    public static let endClearance: CGFloat = 16
    public static let followingThreshold: CGFloat = 48

    public struct RowIdentity: Equatable, Sendable {
        public let id: RowID
        public let order: Int
        public let isAnchorable: Bool

        public init(id: RowID, order: Int, isAnchorable: Bool = true) {
            precondition(!id.isEmpty)
            self.id = id
            self.order = order
            self.isAnchorable = isAnchorable
        }
    }

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

    public struct Layout: Equatable, Sendable {
        public let rows: [RowIdentity]
        public let frames: [RowFrame]
        public let viewport: Viewport
        public let origin: CGFloat
        /// The native document extent, already including the sole end clearance.
        public let documentEnd: CGFloat
        fileprivate let identities: [RowID: RowIdentity]
        fileprivate let measurements: [RowID: RowFrame]
        fileprivate let orderedFrames: [RowFrame]

        public init(rows: [RowIdentity], frames: [RowFrame], viewport: Viewport,
                    origin: CGFloat, documentEnd: CGFloat) {
            precondition(origin.isFinite && documentEnd.isFinite && documentEnd >= 0)
            self.rows = rows
            self.frames = frames
            self.viewport = viewport
            self.origin = origin
            self.documentEnd = documentEnd
            let identities = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let measurements = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0) })
            self.identities = identities
            self.measurements = measurements
            orderedFrames = rows.compactMap { measurements[$0.id] }
            precondition(frames.allSatisfy { frame in
                identities[frame.id] == RowIdentity(id: frame.id, order: frame.order,
                                                    isAnchorable: frame.isAnchorable)
            }, "Measured frames must belong to the canonical layout.")
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
        /// Restores position-based following without moving or reporting reader input.
        case resumeFromCurrentPosition
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
        /// A canonical target that the adapter must bring into measured layout before placement.
        public let needsMeasurement: RowID?

        public init(intent: Intent, origin: CGFloat?, unavailableTarget: RowID? = nil,
                    needsMeasurement: RowID? = nil) {
            precondition(origin?.isFinite != false)
            precondition(origin == nil || (unavailableTarget == nil && needsMeasurement == nil))
            precondition(unavailableTarget == nil || needsMeasurement == nil)
            self.intent = intent
            self.origin = origin
            self.unavailableTarget = unavailableTarget
            self.needsMeasurement = needsMeasurement
        }
    }

    public static func reduce(_ intent: Intent, _ event: Event, rows: [RowFrame],
                              viewport: Viewport, origin: CGFloat) -> Placement {
        precondition(origin.isFinite)
        let currentOrigin: CGFloat
        if case .readerScrolled(let y) = event { currentOrigin = y } else { currentOrigin = origin }
        return reduce(intent, event, layout: completeLayout(rows, viewport: viewport, origin: currentOrigin))
    }

    public static func reduce(_ intent: Intent, _ event: Event, layout: Layout) -> Placement {
        switch event {
        case .readerScrolled(let y):
            precondition(y.isFinite)
            guard y == layout.origin else {
                assertionFailure("Reader input and layout must share the current native origin.")
                return Placement(intent: intent, origin: nil)
            }
            return Placement(intent: intentForPosition(layout, allowsFollowing: true) ?? intent, origin: nil)
        case .holdCurrentPosition:
            if !layout.rows.contains(where: \.isAnchorable) {
                return Placement(intent: intent, origin: nil)
            }
            return Placement(intent: intentForPosition(layout, allowsFollowing: false) ?? intent, origin: nil)
        case .resumeFromCurrentPosition:
            return Placement(intent: intentForPosition(layout, allowsFollowing: true) ?? intent, origin: nil)
        case .land(let target):
            if case .row(let id, _) = target, anchorableIdentity(id, layout: layout) == nil {
                return Placement(intent: intent, origin: nil, unavailableTarget: id)
            }
            return place(.landing(target), layout: layout)
        case .jumpToLatest, .ownPostConfirmed:
            return place(.following, layout: layout)
        case .reveal(let id):
            guard let row = anchorableIdentity(id, layout: layout) else {
                return Placement(intent: intent, origin: nil, unavailableTarget: id)
            }
            return place(.revealing(id, order: row.order), layout: layout)
        case .toggledExpansion(let id, let expanded):
            guard let identity = anchorableIdentity(id, layout: layout) else {
                return Placement(intent: intent, origin: nil, unavailableTarget: id)
            }
            guard let row = layout.measurements[id] else {
                assertionFailure("Expansion requires the clicked row's measured frame.")
                return Placement(intent: intent, origin: nil)
            }
            let offset = row.top - layout.origin - layout.viewport.topInset
            let anchor = Anchor(row: id, order: identity.order, offset: expanded ? offset : max(offset, 0))
            return place(.reading(anchor), layout: layout)
        case .layoutChanged:
            return place(intent, layout: layout)
        }
    }

    /// Projects an existing intent onto current geometry without reducing an event.
    public static func placement(for intent: Intent, rows: [RowFrame], viewport: Viewport) -> Placement {
        place(intent, layout: completeLayout(rows, viewport: viewport, origin: 0))
    }

    public static func placement(for intent: Intent, layout: Layout) -> Placement {
        place(intent, layout: layout)
    }

    public static func layoutEvent(from old: Layout, to new: Layout) -> Event? {
        old.rows != new.rows || old.measurements != new.measurements
            || old.viewport != new.viewport || old.documentEnd != new.documentEnd ? .layoutChanged : nil
    }

    public static func visibleRows(in layout: Layout) -> [RowID] {
        return visibleRows(layout.orderedFrames, viewport: layout.viewport, origin: layout.origin)
    }

    public static func distanceToEnd(in layout: Layout) -> CGFloat {
        return max(0, layout.documentEnd - layout.origin - layout.viewport.height + layout.viewport.bottomInset)
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

    private static func completeLayout(_ rows: [RowFrame], viewport: Viewport, origin: CGFloat) -> Layout {
        Layout(rows: rows.map { .init(id: $0.id, order: $0.order, isAnchorable: $0.isAnchorable) },
               frames: rows, viewport: viewport, origin: origin, documentEnd: end(rows))
    }

    private static func intentForPosition(_ layout: Layout, allowsFollowing: Bool) -> Intent? {
        let distance = distanceToEnd(in: layout)
        if allowsFollowing && distance <= followingThreshold { return .following }
        let anchor = layout.measurements.count == layout.identities.count
            ? readingAnchor(layout.origin, rows: layout.orderedFrames, viewport: layout.viewport)
            : firstRowStartingInView(layout.origin, rows: layout.orderedFrames, viewport: layout.viewport)
        if let anchor {
            return .reading(anchor)
        }
        guard !layout.rows.contains(where: \.isAnchorable) else {
            assertionFailure("Reader capture requires current measured viewport geometry.")
            return nil
        }
        return .following
    }

    private static func readingAnchor(_ origin: CGFloat, rows: [RowFrame], viewport: Viewport) -> Anchor? {
        if let anchor = firstRowStartingInView(origin, rows: rows, viewport: viewport) { return anchor }
        let top = origin + viewport.topInset
        // A gap with no visible row must not retain a landing/reveal intent and later undo input.
        let row = rows.first(where: { $0.isAnchorable && $0.top >= top }) ?? rows.last(where: \.isAnchorable)
        return row.map { Anchor(row: $0.id, order: $0.order, offset: $0.top - top) }
    }

    private static func place(_ intent: Intent, layout: Layout) -> Placement {
        let viewport = layout.viewport
        let proposed: CGFloat
        switch intent {
        case .following, .landing(.end):
            proposed = layout.documentEnd - viewport.height + viewport.bottomInset
        case .landing(.row(let id, let order)):
            guard let identity = survivor(id: id, order: order, layout: layout) else {
                return place(.following, layout: layout)
            }
            guard let row = layout.measurements[identity.id] else {
                return Placement(intent: intent, origin: nil, needsMeasurement: identity.id)
            }
            proposed = row.top - viewport.topInset
        case .reading(let anchor):
            guard let identity = survivor(id: anchor.row, order: anchor.order, layout: layout) else {
                return place(.following, layout: layout)
            }
            guard let row = layout.measurements[identity.id] else {
                return Placement(intent: intent, origin: nil, needsMeasurement: identity.id)
            }
            proposed = row.top - viewport.topInset - anchor.offset
        case .revealing(let id, let order):
            guard let identity = survivor(id: id, order: order, layout: layout) else {
                return place(.following, layout: layout)
            }
            guard let row = layout.measurements[identity.id] else {
                return Placement(intent: intent, origin: nil, needsMeasurement: identity.id)
            }
            let middle = viewport.topInset + viewport.unobscuredHeight / 2
            proposed = row.top + row.height / 2 - middle
        }
        let minimum = -viewport.topInset
        let maximum = max(minimum, layout.documentEnd - viewport.height + viewport.bottomInset)
        return Placement(intent: intent, origin: min(maximum, max(minimum, proposed)))
    }

    private static func survivor(id: RowID, order: Int, layout: Layout) -> RowIdentity? {
        anchorableIdentity(id, layout: layout) ?? layout.rows.first(where: { $0.isAnchorable && $0.order >= order })
            ?? layout.rows.last(where: \.isAnchorable)
    }

    private static func anchorableIdentity(_ id: RowID, layout: Layout) -> RowIdentity? {
        layout.identities[id].flatMap { $0.isAnchorable ? $0 : nil }
    }
}
