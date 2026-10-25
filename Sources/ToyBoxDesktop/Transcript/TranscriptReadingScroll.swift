import ChannelKit
import SwiftUI

struct TranscriptNativeLayout {
    let viewport: TranscriptScrollModel.Viewport
    let origin: CGFloat
    let documentEnd: CGFloat
    let documentWidth: CGFloat
}

@MainActor
final class TranscriptReadingScroll {
    typealias Model = TranscriptScrollModel

    private var rows: [Model.RowIdentity] = []
    private var projectedRows: [TranscriptRow] = []
    private var expandedIDs: Set<String> = []
    private var identities: [String: Model.RowIdentity] = [:]
    private var targets: [String: String] = [:]
    private var layout: Model.Layout?
    private(set) var intent: Model.Intent = .following
    private var pendingReader = true

    var isReading: Bool {
        if case .reading = intent { return true }
        return false
    }

    func configure(rows: [TranscriptRow], expandedIDs: Set<String>) {
        guard rows != projectedRows || expandedIDs != self.expandedIDs else { return }
        projectedRows = rows
        self.expandedIDs = expandedIDs
        self.rows = transcriptScrollIdentities(rows, expandedMessageIds: expandedIDs)
        identities = Dictionary(uniqueKeysWithValues: self.rows.map { ($0.id, $0) })
        targets = [:]
        for row in rows {
            targets[row.id] = row.id
            targets["divider-\(row.id)"] = row.id
            targets["system-group-\(row.id)"] = row.id
            for message in row.messages {
                targets[message.id] = transcriptLazyRowID(containing: message.id, in: row)
            }
        }
    }

    func readerMoved() { pendingReader = true }

    func release() {
        pendingReader = true
        intent = .following
        layout = nil
    }

    func receive(frames: [String: TranscriptMessageFrame], native: TranscriptNativeLayout,
                 historyStart: Int) -> (id: String, anchor: UnitPoint)? {
        func isCurrent(_ frame: TranscriptMessageFrame) -> Bool {
            guard frame.historyStart == historyStart, let size = frame.layoutSize else { return false }
            return abs(size.width + 2 * ConversationRail.inset - native.documentWidth) <= 0.5
                && abs(size.height + TranscriptCoordinates.contentTopPadding - native.documentEnd) <= 0.5
        }
        let measured = frames.compactMap { id, frame -> Model.RowFrame? in
            guard let identity = identities[id], isCurrent(frame) else { return nil }
            let top = TranscriptCoordinates.contentTopPadding + frame.contentTop
            guard top >= -0.5, top + frame.rect.height <= native.documentEnd + 0.5 else { return nil }
            return .init(id: id, order: identity.order, top: top, height: frame.rect.height,
                         isAnchorable: identity.isAnchorable)
        }.sorted { $0.order < $1.order }
        guard !measured.isEmpty else { return nil }
        let next = Model.Layout(rows: rows, frames: measured, viewport: native.viewport,
                                origin: native.origin, documentEnd: native.documentEnd)
        defer { layout = next }
        if pendingReader {
            guard Model.firstRowStartingInView(next.origin, rows: measured, viewport: next.viewport) != nil
            else { return nil }
            intent = Model.reduce(intent, .readerScrolled(to: next.origin), layout: next).intent
            pendingReader = false
            transcriptScrollTrace("reading.capture width=\(native.viewport.width) origin=\(native.origin)"
                                  + " intent=\(intent)")
            return nil
        }
        guard let layout, Model.layoutEvent(from: layout, to: next) != nil,
              case .reading(let anchor) = intent else { return nil }
        let placement = Model.reduce(intent, .layoutChanged, layout: next)
        if let id = placement.needsMeasurement, let target = targets[id] {
            transcriptScrollTrace("reading.materialize target=\(target) intent=\(intent)")
            return (target, .top)
        }
        guard let origin = placement.origin, abs(origin - next.origin) > 0.5,
              let target = targets[anchor.row], let frame = frames["scroll-row-\(target)"],
              isCurrent(frame), next.viewport.unobscuredHeight > 0 else { return nil }
        // SwiftUI aligns the padded lazy row, while the model keeps the message inside it.
        let alignmentRange = next.viewport.unobscuredHeight - frame.rect.height
        guard abs(alignmentRange) > 0.5 else {
            assertionFailure("A viewport-height row has no UnitPoint for an arbitrary point offset.")
            return nil
        }
        let offset = TranscriptCoordinates.contentTopPadding + frame.contentTop - origin - next.viewport.topInset
        transcriptScrollTrace("reading.place target=\(target) origin=\(next.origin)->\(origin)"
                              + " intent=\(intent) offset=\(offset)")
        return (target, .init(x: 0, y: offset / alignmentRange))
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
