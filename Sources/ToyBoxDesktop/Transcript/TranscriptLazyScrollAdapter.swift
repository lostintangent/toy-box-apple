import AppKit
import ChannelKit

struct TranscriptNativeLayout: Equatable {
    let viewport: TranscriptScrollModel.Viewport
    let origin: CGFloat
    let documentEnd: CGFloat
    let documentWidth: CGFloat

    init(viewport: TranscriptScrollModel.Viewport, origin: CGFloat, documentEnd: CGFloat,
         documentWidth: CGFloat? = nil) {
        self.viewport = viewport
        self.origin = origin
        self.documentEnd = documentEnd
        self.documentWidth = documentWidth ?? viewport.width
    }

    init?(scrollView: NSScrollView) {
        guard let document = scrollView.documentView, document.isFlipped else { return nil }
        let bounds = scrollView.contentView.bounds
        let insets = scrollView.contentInsets
        self.init(viewport: .init(width: bounds.width, height: bounds.height,
                                 topInset: max(0, insets.top), bottomInset: max(0, insets.bottom)),
                  origin: bounds.minY, documentEnd: document.bounds.height, documentWidth: document.bounds.width)
    }
}

@MainActor
final class TranscriptLazyScrollAdapter {
    typealias Model = TranscriptScrollModel
    private static let traces = ProcessInfo.processInfo.environment["TOY_BOX_SCROLL_TRACE"] == "1"

    private(set) var intent: Model.Intent = .following
    private var rows: [Model.RowIdentity] = []
    private var identities: [String: Model.RowIdentity] = [:]
    private var projectedRows: [TranscriptRow] = []
    private var expandedMessageIds: Set<String> = []
    private var attemptIDs: [String] = []
    private var materializationRows: [String: String] = [:]
    private var layout: Model.Layout?
    private var pendingReaderInput = false
    private var pendingEvent: Model.Event?
    private var requestedMeasurement: String?
    private(set) var command: UUID?
    private(set) var isAligned = false
    private var isReady = false

    var followsLatest: Bool {
        switch intent {
        case .following, .landing(.end): true
        default: false
        }
    }

    var blocksRead: Bool { pendingReaderInput || pendingEvent != nil || !isAligned }
    var isTargeting: Bool { !isReady || pendingEvent != nil || requestedMeasurement != nil || !isAligned }

    func visibleRows() -> [String] {
        guard !blocksRead, let layout else { return [] }
        return Model.visibleRows(in: layout)
    }

    func target(for id: String) -> Model.Target? {
        identities[id].map { .row(id, order: $0.order) }
    }

    func configure(rows: [TranscriptRow], expandedMessageIds: Set<String>, attemptIDs: [String] = []) {
        guard rows != projectedRows || expandedMessageIds != self.expandedMessageIds
                || attemptIDs != self.attemptIDs else { return }
        projectedRows = rows
        self.expandedMessageIds = expandedMessageIds
        self.attemptIDs = attemptIDs
        self.rows = transcriptScrollIdentities(rows, expandedMessageIds: expandedMessageIds)
        let attemptOrder = (self.rows.last?.order ?? 0) + 1
        self.rows.append(contentsOf: attemptIDs.enumerated().map {
            .init(id: "attempt-\($0.element)", order: attemptOrder + $0.offset)
        })
        identities = Dictionary(uniqueKeysWithValues: self.rows.map { ($0.id, $0) })
        materializationRows.removeAll(keepingCapacity: true)
        for row in rows {
            materializationRows[row.id] = row.id
            materializationRows["divider-\(row.id)"] = row.id
            for message in row.messages { materializationRows[message.id] = row.id }
        }
        for id in attemptIDs { materializationRows["attempt-\(id)"] = "attempt-\(id)" }
    }

    @discardableResult
    func request(_ event: Model.Event) -> UUID {
        let token = UUID()
        command = token
        pendingEvent = event
        requestedMeasurement = nil
        pendingReaderInput = false
        isAligned = false
        isReady = true
        return token
    }

    func readerWillScroll() {
        command = nil
        pendingEvent = nil
        requestedMeasurement = nil
        pendingReaderInput = true
        isAligned = false
    }

    func readerScrolled(frames: [String: TranscriptMessageFrame], native: TranscriptNativeLayout,
                        historyStart: Int) {
        readerWillScroll()
        isReady = true
        guard let next = makeLayout(frames: frames, native: native, historyStart: historyStart) else { return }
        captureReader(in: next)
        if Self.traces { print("MODEL_READER y=\(native.origin) width=\(native.viewport.width) intent=\(intent)") }
        layout = next
    }

    func framesChanged(frames: [String: TranscriptMessageFrame], native: TranscriptNativeLayout,
                       historyStart: Int) -> Model.Placement? {
        guard let next = makeLayout(frames: frames, native: native, historyStart: historyStart) else { return nil }
        return receive(next)
    }

    private func receive(_ next: Model.Layout) -> Model.Placement? {
        defer { layout = next }
        guard isReady else { return nil }
        if pendingReaderInput {
            captureReader(in: next)
            return nil
        }
        var placement: Model.Placement
        if let event = pendingEvent {
            switch event {
            case .holdCurrentPosition:
                guard canCapture(in: next, allowsFollowing: false) else { return nil }
            case .resumeFromCurrentPosition:
                guard canCapture(in: next, allowsFollowing: true) else { return nil }
            default: break
            }
            placement = Model.reduce(intent, event, layout: next)
            pendingEvent = nil
        } else {
            if let layout, Model.layoutEvent(from: layout, to: next) == nil,
               abs(layout.origin - next.origin) <= 0.25, isAligned { return nil }
            placement = Model.placement(for: intent, layout: next)
        }
        if placement.needsMeasurement != nil, case .reading = intent, let layout {
            let currentIDs = Set(next.frames.map(\.id))
            let common = layout.frames.filter { currentIDs.contains($0.id) }
            let previous = Model.Layout(rows: layout.rows, frames: common, viewport: layout.viewport,
                                        origin: layout.origin, documentEnd: layout.documentEnd)
            if canCapture(in: previous, allowsFollowing: false) {
                intent = Model.reduce(intent, .holdCurrentPosition, layout: previous).intent
                placement = Model.placement(for: intent, layout: next)
            }
        }
        intent = placement.intent
        if Self.traces {
            print("MODEL_PLACE width=\(next.viewport.width) y=\(next.origin) end=\(next.documentEnd)"
                  + " intent=\(intent) origin=\(String(describing: placement.origin))"
                  + " needs=\(String(describing: placement.needsMeasurement))"
                  + " frames=\(next.frames.map { "\($0.id):\($0.top)" }.joined(separator: ","))")
        }
        isAligned = placement.origin.map { abs($0 - next.origin) <= 0.5 }
            ?? (placement.needsMeasurement == nil && placement.unavailableTarget == nil)
        if placement.origin != nil { requestedMeasurement = nil }
        return placement
    }

    func nativeGeometryChanged(frames: [String: TranscriptMessageFrame], native: TranscriptNativeLayout,
                               historyStart: Int) -> Model.Placement? {
        if followsLatest, pendingEvent == nil, !pendingReaderInput {
            return receive(.init(rows: rows, frames: [], viewport: native.viewport,
                                 origin: native.origin, documentEnd: native.documentEnd))
        }
        return framesChanged(frames: frames, native: native, historyStart: historyStart)
    }

    func materializationRow(for id: String) -> String? {
        switch intent {
        case .landing, .revealing: break
        case .reading, .following: return nil
        }
        guard let row = materializationRows[id], requestedMeasurement != row else { return nil }
        requestedMeasurement = row
        return row
    }

    func captureExpansion(_ id: String, expanded: Bool, frames: [String: TranscriptMessageFrame],
                          native: TranscriptNativeLayout, historyStart: Int) -> Bool {
        guard let next = makeLayout(frames: frames, native: native, historyStart: historyStart) else { return false }
        guard next.frames.contains(where: { $0.id == id }) else { return false }
        intent = Model.reduce(intent, .toggledExpansion(id, expanded: expanded), layout: next).intent
        layout = next
        pendingReaderInput = false
        pendingEvent = nil
        command = UUID()
        isReady = true
        isAligned = false
        return true
    }

    private func captureReader(in layout: Model.Layout) {
        guard canCapture(in: layout, allowsFollowing: true) else { return }
        intent = Model.reduce(intent, .readerScrolled(to: layout.origin), layout: layout).intent
        pendingReaderInput = false
        isAligned = true
    }

    private func canCapture(in layout: Model.Layout, allowsFollowing: Bool) -> Bool {
        !layout.rows.contains(where: \.isAnchorable)
            || (allowsFollowing && Model.distanceToEnd(in: layout) <= Model.followingThreshold)
            || hasVisibleFrame(in: layout)
    }

    private func hasVisibleFrame(in layout: Model.Layout) -> Bool {
        Model.firstRowStartingInView(layout.origin, rows: layout.frames,
                                    viewport: layout.viewport) != nil
    }

    private func makeLayout(frames: [String: TranscriptMessageFrame], native: TranscriptNativeLayout,
                            historyStart: Int) -> Model.Layout? {
        let measured = frames.compactMap { id, frame -> Model.RowFrame? in
            guard frame.historyStart == historyStart, let identity = identities[id] else { return nil }
            if let size = frame.layoutSize {
                guard abs(size.width + 2 * ConversationRail.inset - native.documentWidth) <= 0.5,
                      abs(size.height + TranscriptCoordinates.contentTopPadding - native.documentEnd) <= 0.5
                else { return nil }
            }
            let top = TranscriptCoordinates.contentTopPadding + frame.contentTop
            guard top >= -0.5, top + frame.rect.height <= native.documentEnd + 0.5 else { return nil }
            return .init(id: id, order: identity.order,
                         top: top,
                         height: frame.rect.height, isAnchorable: identity.isAnchorable)
        }.sorted { $0.order < $1.order }
        if Self.traces, measured.isEmpty, let frame = frames.values.first {
            print("MODEL_EMPTY native=\(native.viewport.width)x\(native.documentEnd)"
                  + " source=\(String(describing: frame.layoutSize)) frames=\(frames.count)"
                  + " rows=\(rows.count) start=\(historyStart)/\(frame.historyStart)")
        }
        guard frames.isEmpty || !measured.isEmpty || !rows.contains(where: \.isAnchorable) else { return nil }
        return .init(rows: rows, frames: measured, viewport: native.viewport,
                     origin: native.origin, documentEnd: native.documentEnd)
    }
}

func transcriptScrollIdentities(_ rows: [TranscriptRow], expandedMessageIds: Set<String>)
    -> [TranscriptScrollModel.RowIdentity] {
    var identities: [TranscriptScrollModel.RowIdentity] = []
    for row in rows {
        guard let first = row.messages.first else { continue }
        if row.divider != nil {
            identities.append(.init(id: "divider-\(row.id)", order: first.sequence * 4))
        }
        switch row.content {
        case .user(let message):
            identities.append(.init(id: message.id, order: message.sequence * 4 + 1))
        case .agent(_, let entries):
            identities.append(contentsOf: entries.map {
                .init(id: $0.message.id, order: $0.message.sequence * 4 + 1)
            })
        case .system(let messages):
            let membership = first.system?.type == "member_joined" || first.system?.type == "member_left"
            let individual = first.system?.type == "artifact_shared"
                || (membership && messages.contains { expandedMessageIds.contains($0.id) })
            if individual {
                identities.append(.init(id: "system-group-\(row.id)", order: first.sequence * 4 + 1,
                                        isAnchorable: false))
                identities.append(contentsOf: messages.map {
                    .init(id: $0.id, order: $0.sequence * 4 + 2)
                })
            } else {
                identities.append(.init(id: row.id, order: first.sequence * 4 + 1))
            }
        }
    }
    return identities
}
