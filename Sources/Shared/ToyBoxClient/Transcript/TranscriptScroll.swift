import Foundation
import ToyBoxKit

/// Places the transcript with ToyBoxKit's scroll model. Geometry reports feed it and its placements
/// go to the native scroll position. It never re-renders the transcript, so frame reports stay cheap.
@MainActor
public final class TranscriptScroll {
    public typealias Model = TranscriptPlacement

    public static let endID = "transcript-end"

    /// How near a placement the scroll is once it's there. SwiftUI rounds the content size up to a
    /// whole point and the scroll to a pixel, so a scroll resting on the end view can read up to a
    /// point and a pixel short of the model's end. Asking again would move nothing at rest, and
    /// mid-transition it can land somewhere else.
    public static let settled: CGFloat = 1.5

    public struct Metrics: Equatable {
        public var viewport: Model.Viewport
        public var origin: CGFloat
        public var documentEnd: CGFloat
        /// How far the top of the content sits above the top of the unobscured viewport.
        var top: CGFloat { origin + viewport.topInset }

        public init(viewport: Model.Viewport, origin: CGFloat, documentEnd: CGFloat) {
            self.viewport = viewport
            self.origin = origin
            self.documentEnd = documentEnd
        }
    }

    var rows: [Model.RowIdentity] = []
    /// How many messages the transcript showed when geometry last synced the rows.
    public var messageCount = 0
    public var metrics: Metrics? {
        didSet {
            guard let base = endBeforePage, let end = metrics?.documentEnd, end != base else { return }
            frames = frames.mapValues { Model.keepingDistanceToEnd($0, from: base, to: end) }
            endBeforePage = nil
        }
    }
    public var isReaderScrolling = false
    public var isScrollIdle = true
    /// Geometry reported while the scene isn't active comes from the system's snapshot passes,
    /// not the reader's layout, so nothing is placed from it until the scene is active again.
    public var isSceneActive = true
    /// Keeps the model's placement through reader scrolling until geometry holds it: an anchor
    /// through a page insertion, or the end after a move that stopped a flick still reporting frames.
    public var holdsPlacementThroughInput = false
    /// Where a page's move started. The reader's finger can move in the same frame that move lands,
    /// so it has landed once the scroll is nearer the placement than where it started.
    private var pageMoveStart: CGFloat?
    /// The content's end before a page above grew it, until geometry reports the growth.
    private var endBeforePage: CGFloat?
    /// The reader's row while a page above it is placed. The lazy stack reports the rows it had built
    /// at estimated places until it lays them out again, so its frame only changes on screen.
    private var settling: String?
    /// The reader was scrolling when a page moved them. SwiftUI reports the rest of that input as idle,
    /// until a new touch or a change of viewport, like the keyboard or a posture change.
    private var scrollsPastPhase = false
    private(set) var intent: Model.Intent = .landing(.end)
    public private(set) var hasLanded = false
    /// Whether the transcript keeps its end in view, having landed there or followed it since.
    public var followsEnd: Bool { hasLanded && (intent == .following || intent == .landing(.end)) }
    /// While Find is open, arrivals never move the conversation, so the result being read stays put.
    private(set) var isFinding = false
    /// What the reader was doing when Find opened, which closing puts back unless they scrolled or
    /// revealed a result meanwhile.
    private var beforeFind: Model.Intent?
    private var frames: [String: CGRect] = [:]
    private var column: CGFloat?
    private var lastLayout: Model.Layout?

    public init() {}

    /// Adopts the transcript's current rows once. Geometry can report a page's growth before
    /// `onChange(items)`, so it syncs first, and a reveal syncs before placing, because it can resume
    /// after a page lands but before SwiftUI reports the change.
    public func sync(_ current: [Model.RowIdentity], pinsLanding: Bool = false) {
        guard current != rows else { return }
        if let anchor = rows.first?.id, current.first?.id != anchor, current.contains(where: { $0.id == anchor }),
           hasLanded, let metrics {
            // Older history arrived above: keep the reader's row where it was.
            _ = update(.holdCurrentPosition)
            holdsPlacementThroughInput = true
            pageMoveStart = metrics.origin
            endBeforePage = metrics.documentEnd
            if case .reading(let anchor) = intent { settling = anchor.row }
            scrollsPastPhase = isReaderScrolling
        }
        if let last = rows.last?.id, current.last?.id != last, current.contains(where: { $0.id == last }), hasLanded {
            // While Find is open, an arrival never moves the conversation, even below a revealed result.
            _ = update(isFinding ? .holdCurrentPosition : .arrived(pinsLanding: pinsLanding))
        }
        rows = current
    }

    /// A row keeps its frame after it scrolls away. The lazy stack caches it and calls onDisappear,
    /// but its content frame is unchanged when it returns, so it would never report again. Frames
    /// span the column instead of the row, so a new width means the stack re-laid out every row it
    /// holds, and they all report again. Any frame left from the old width is stale.
    public func measure(_ id: String, frame: CGRect) {
        if frame.width != column {
            frames.removeAll()
            column = frame.width
        }
        if id == settling, let metrics {
            guard frame.maxY > metrics.origin, frame.minY < metrics.origin + metrics.viewport.height else { return }
            settling = nil
            endBeforePage = nil
        }
        frames[id] = frame
    }

    private var measured: [Model.RowFrame] {
        rows.compactMap { row in
            frames[row.id].map { Model.RowFrame(id: row.id, order: row.order, top: $0.minY, height: $0.height) }
        }
    }

    public var layout: Model.Layout? {
        guard let metrics, metrics.viewport.width > 0 else { return nil }
        return Model.Layout(rows: rows, frames: measured, viewport: metrics.viewport,
                            origin: metrics.origin, documentEnd: max(0, metrics.documentEnd))
    }

    /// Reduces an explicit event, or derives reader input and geometry changes when there's none.
    public func update(_ explicit: Model.Event? = nil) -> Model? {
        guard let layout else { return nil }
        defer { lastLayout = layout }
        if holdsPlacementThroughInput, endBeforePage == nil,
           let origin = Model.placement(for: intent, layout: layout).origin,
           abs(origin - layout.origin) <= Self.settled
            || pageMoveStart.map({ abs(origin - layout.origin) < abs($0 - layout.origin) }) == true {
            holdsPlacementThroughInput = false
            pageMoveStart = nil
            settling = nil
        }
        let event: Model.Event
        if let explicit {
            event = explicit
            switch explicit {
            case .layoutChanged, .holdCurrentPosition, .arrived: break
            default: beforeFind = nil
            }
        } else if !isSceneActive || !hasLanded {
            return nil
        } else if !holdsPlacementThroughInput, isReaderScrolling || readerMoved(from: lastLayout, to: layout) {
            beforeFind = nil
            event = isFinding ? .holdCurrentPosition : .readerScrolled(to: layout.origin)
        } else if let last = lastLayout {
            guard let change = Model.layoutEvent(from: last, to: layout) else {
                return nil
            }
            event = change
        } else {
            event = .layoutChanged
        }
        if capturesPosition(event), !hasViewportGeometry { return nil }
        var placement = Model.reduce(intent, event, layout: layout)
        // Asking for a row the stack hasn't built from past the end can leave the scroll past the end
        // again, as the content shrinks under SwiftUI's estimate. The end is built with the rows above
        // it, so it comes first, and the row is placed from there.
        if placement.needsMeasurement != nil, restsPastEnd(layout) {
            placement = Model(intent: placement.intent, origin: endOrigin(layout))
        }
        intent = placement.intent
        switch event {
        case .land: hasLanded = true
        // A request alert's reveal replaces the first landing.
        case .reveal where placement.unavailableTarget == nil: hasLanded = true
        case .jumpToLatest: holdsPlacementThroughInput = true
        default: break
        }
        return placement
    }

    private func endOrigin(_ layout: Model.Layout) -> CGFloat {
        max(-layout.viewport.topInset, layout.documentEnd - layout.viewport.height + layout.viewport.bottomInset)
    }

    /// Past the end is never where a placement left the scroll, so resting there means the scroll
    /// didn't apply, and nothing is drawn.
    private func restsPastEnd(_ layout: Model.Layout) -> Bool {
        isScrollIdle && layout.origin > endOrigin(layout) + Self.settled
    }

    /// Where the rest of the reader's input took the scroll after a page moved them mid-scroll.
    /// Anything else that moves only the origin, like the stack dropping a placement, leaves the
    /// reader's anchor alone, and so does our own move landing.
    private func readerMoved(from last: Model.Layout?, to layout: Model.Layout) -> Bool {
        guard scrollsPastPhase, case .reading = intent, let last else { return false }
        guard last.viewport == layout.viewport else {
            scrollsPastPhase = false
            return false
        }
        let placed = Model.placement(for: intent, layout: layout).origin
        return last.origin != layout.origin && placed.map { abs($0 - layout.origin) > Self.settled } != false
    }

    /// Opening Find leaves the placement alone, so its keyboard keeps the end in view like the
    /// composer's. Closing puts back what the reader was doing, or where they moved to, following
    /// again within the threshold of the end like any reader who stops there.
    public func findChanged(isPresented: Bool) -> Model? {
        guard isPresented != isFinding else { return nil }
        isFinding = isPresented
        guard hasLanded else { return nil }
        guard !isPresented else {
            beforeFind = intent
            return nil
        }
        if let before = beforeFind {
            beforeFind = nil
            intent = before
            return update(.layoutChanged)
        }
        return metrics.flatMap { update(.readerScrolled(to: $0.origin)) }
    }

    /// Places once for the geometry the scene came back with.
    public func sceneBecameActive() -> Model? {
        isSceneActive = true
        return hasLanded ? update(.layoutChanged) : nil
    }

    /// Lands once connected, like the Mac. A reopened store's cached messages predate its new
    /// unread boundary, which the next snapshot or resume captures.
    public func canLand(in store: ChannelStore, hasRows: Bool) -> Bool {
        !hasLanded && store.isLoaded && store.phase.isConnected && hasRows
    }

    /// A new touch is the reader's own, unlike the frames of a flick that a jump stopped.
    public func readerTouched() {
        scrollsPastPhase = false
        if intent == .following { holdsPlacementThroughInput = false }
    }

    private func capturesPosition(_ event: Model.Event) -> Bool {
        switch event {
        case .readerScrolled, .holdCurrentPosition: true
        default: false
        }
    }

    /// Reading a position needs a measured row in view. A lazy stack can briefly show rows it
    /// hasn't reported yet, such as a page inserted above, and the next measurement resolves it.
    private var hasViewportGeometry: Bool {
        guard let metrics else { return false }
        let measured = measured
        return measured.count == rows.count
            || Model.firstRowStartingInView(metrics.origin, rows: measured, viewport: metrics.viewport) != nil
    }

    /// Whether the top of the content is within a screen, with nothing of ours still being placed, so a
    /// page lands before the reader gets there. That covers scrolling up, a landing or filter that
    /// can't fill the screen, and a short page. While a landing or page is still being placed, its old
    /// geometry says nothing. A reader's anchor is never re-asserted at rest, so geometry that has
    /// moved past it, like a flick's last frame after its phase ends or a tap on the status bar, is
    /// where the reader is.
    var reachesOlder: Bool {
        guard hasLanded, let metrics, metrics.top < metrics.viewport.height, let layout else { return false }
        if case .reading = intent, !holdsPlacementThroughInput { return true }
        guard let origin = Model.placement(for: intent, layout: layout).origin else { return false }
        return abs(origin - layout.origin) <= Self.settled
    }

    /// Whether to page now. Geometry can report a merged page before `onChange(items)` syncs it,
    /// and the old rows would make that grown content look settled with the top still in reach.
    public func loadsOlder(with current: @autoclosure () -> [Model.RowIdentity]) -> Bool {
        reachesOlder && current() == rows
    }

    /// Whether a placement asks the scroll view to move, so the current geometry is about to be replaced.
    public func moves(_ placement: Model?) -> Bool {
        guard let placement else { return false }
        if let origin = placement.origin { return metrics.map { abs(origin - $0.origin) > Self.settled } ?? false }
        return placement.needsMeasurement != nil
    }

    /// Whether Jump to Latest shows, read only from settled geometry, or nil to leave it as it is.
    /// While a placement moves the scroll, the distance is about to change, and toggling the button
    /// would resize the bar under the scroll and send the placement again.
    public func showsJumpToLatest(after placement: Model?) -> Bool? {
        guard !moves(placement) else { return nil }
        return hasLanded && distanceToEnd > Model.followingThreshold
    }

    public var distanceToEnd: CGFloat { layout.map(Model.distanceToEnd(in:)) ?? 0 }
}
