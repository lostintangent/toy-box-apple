import AppKit
import ChannelKit

struct TranscriptNativeLayout: Equatable {
    let viewport: TranscriptScrollModel.Viewport
    let origin: CGFloat
    let documentEnd: CGFloat

    init(viewport: TranscriptScrollModel.Viewport, origin: CGFloat, documentEnd: CGFloat) {
        self.viewport = viewport
        self.origin = origin
        self.documentEnd = documentEnd
    }

    init?(scrollView: NSScrollView) {
        guard let document = scrollView.documentView, document.isFlipped else { return nil }
        let bounds = scrollView.contentView.bounds
        let insets = scrollView.contentInsets
        self.init(viewport: .init(width: bounds.width, height: bounds.height,
                                 topInset: max(0, insets.top), bottomInset: max(0, insets.bottom)),
                  origin: bounds.minY, documentEnd: document.bounds.height)
    }
}

@MainActor
final class TranscriptLazyScrollAdapter {
    typealias Model = TranscriptScrollModel

    private(set) var intent: Model.Intent = .following
    private var rows: [Model.RowIdentity] = []
    private var identities: [String: Model.RowIdentity] = [:]
    private var projectedRows: [TranscriptRow] = []
    private var expandedMessageIds: Set<String> = []
    private var materializationRows: [String: String] = [:]
    private var layout: Model.Layout?
    private var wasHolding = false
    private var pendingReaderInput = false

    func configure(rows: [TranscriptRow], expandedMessageIds: Set<String>) {
        guard rows != projectedRows || expandedMessageIds != self.expandedMessageIds else { return }
        projectedRows = rows
        self.expandedMessageIds = expandedMessageIds
        self.rows = transcriptScrollIdentities(rows, expandedMessageIds: expandedMessageIds)
        identities = Dictionary(uniqueKeysWithValues: self.rows.map { ($0.id, $0) })
        materializationRows.removeAll(keepingCapacity: true)
        for row in rows {
            materializationRows[row.id] = row.id
            materializationRows["divider-\(row.id)"] = row.id
            for message in row.messages { materializationRows[message.id] = row.id }
        }
    }

    func reset() {
        intent = .following
        layout = nil
        wasHolding = false
        pendingReaderInput = false
    }

    func readerScrolled(frames: [String: TranscriptMessageFrame], native: TranscriptNativeLayout,
                        historyStart: Int) {
        pendingReaderInput = true
        let next = makeLayout(frames: frames, native: native, historyStart: historyStart)
        captureReader(in: next)
        layout = next
    }

    func framesChanged(frames: [String: TranscriptMessageFrame], native: TranscriptNativeLayout,
                       historyStart: Int, holdsReading: Bool) -> Model.Placement? {
        let next = makeLayout(frames: frames, native: native, historyStart: historyStart)
        defer {
            layout = next
            wasHolding = holdsReading
        }
        if pendingReaderInput {
            captureReader(in: next)
            return nil
        }
        guard holdsReading else { return nil }
        if !wasHolding, case .following = intent {
            guard hasVisibleFrame(in: next) else { return nil }
            intent = Model.reduce(intent, .holdCurrentPosition, layout: next).intent
        }
        if let layout, Model.layoutEvent(from: layout, to: next) == nil { return nil }
        let placement = Model.reduce(intent, .layoutChanged, layout: next)
        intent = placement.intent
        return placement
    }

    func materializationRow(for id: String) -> String? { materializationRows[id] }

    func captureExpansion(_ id: String, expanded: Bool, frames: [String: TranscriptMessageFrame],
                          native: TranscriptNativeLayout, historyStart: Int) -> Bool {
        let next = makeLayout(frames: frames, native: native, historyStart: historyStart)
        guard next.frames.contains(where: { $0.id == id }) else { return false }
        intent = Model.reduce(intent, .toggledExpansion(id, expanded: expanded), layout: next).intent
        layout = next
        pendingReaderInput = false
        return true
    }

    private func captureReader(in layout: Model.Layout) {
        guard Model.distanceToEnd(in: layout) <= Model.followingThreshold || hasVisibleFrame(in: layout) else {
            return
        }
        intent = Model.reduce(intent, .readerScrolled(to: layout.origin), layout: layout).intent
        pendingReaderInput = false
    }

    private func hasVisibleFrame(in layout: Model.Layout) -> Bool {
        Model.firstRowStartingInView(layout.origin, rows: layout.frames,
                                    viewport: layout.viewport) != nil
    }

    private func makeLayout(frames: [String: TranscriptMessageFrame], native: TranscriptNativeLayout,
                            historyStart: Int) -> Model.Layout {
        let measured = frames.compactMap { id, frame -> Model.RowFrame? in
            guard frame.historyStart == historyStart, let identity = identities[id] else { return nil }
            return .init(id: id, order: identity.order,
                         top: TranscriptCoordinates.contentTopPadding + frame.contentTop,
                         height: frame.rect.height, isAnchorable: identity.isAnchorable)
        }.sorted { $0.order < $1.order }
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
