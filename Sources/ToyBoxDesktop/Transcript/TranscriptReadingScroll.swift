import AppKit
import ChannelKit
import SwiftUI

struct TranscriptNativeLayout {
    let viewport: TranscriptScrollModel.Viewport
    let origin: CGFloat
    let documentEnd: CGFloat
    let documentWidth: CGFloat

    init?(scrollView: NSScrollView) {
        guard let document = scrollView.documentView, document.isFlipped else { return nil }
        let bounds = scrollView.contentView.bounds
        let insets = scrollView.contentInsets
        viewport = .init(width: bounds.width, height: bounds.height,
                         topInset: max(0, insets.top), bottomInset: max(0, insets.bottom))
        origin = bounds.minY
        documentEnd = document.bounds.height
        documentWidth = document.bounds.width
    }
}

@MainActor
final class TranscriptReadingScroll {
    typealias Model = TranscriptScrollModel
    private static let traces = ProcessInfo.processInfo.environment["TOY_BOX_SCROLL_TRACE"] == "1"

    private var rows: [Model.RowIdentity] = []
    private var projectedRows: [TranscriptRow] = []
    private var expandedIDs: Set<String> = []
    private var identities: [String: Model.RowIdentity] = [:]
    private var layout: Model.Layout?
    private var intent: Model.Intent = .following
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
    }

    func readerMoved() {
        pendingReader = true
    }

    func release() {
        pendingReader = true
        intent = .following
        layout = nil
    }

    func receive(frames: [String: TranscriptMessageFrame], native: TranscriptNativeLayout,
                 historyStart: Int) -> (id: String, anchor: UnitPoint)? {
        let measured = frames.compactMap { id, frame -> Model.RowFrame? in
            guard frame.historyStart == historyStart, let identity = identities[id],
                  let size = frame.layoutSize,
                  abs(size.width + 2 * ConversationRail.inset - native.documentWidth) <= 0.5,
                  abs(size.height + TranscriptCoordinates.contentTopPadding - native.documentEnd) <= 0.5
            else { return nil }
            let top = TranscriptCoordinates.contentTopPadding + frame.contentTop
            guard top >= -0.5, top + frame.rect.height <= native.documentEnd + 0.5 else { return nil }
            return .init(id: id, order: identity.order, top: top, height: frame.rect.height,
                         isAnchorable: identity.isAnchorable)
        }.sorted { $0.order < $1.order }
        guard !measured.isEmpty else {
            if Self.traces {
                print("READ_REJECT native=\(native.documentWidth)x\(native.documentEnd)"
                      + " source=\(String(describing: frames.values.first?.layoutSize))")
            }
            return nil
        }
        let next = Model.Layout(rows: rows, frames: measured, viewport: native.viewport,
                                origin: native.origin, documentEnd: native.documentEnd)
        defer { layout = next }
        if pendingReader {
            guard Model.firstRowStartingInView(next.origin, rows: measured, viewport: next.viewport) != nil
            else { return nil }
            intent = Model.reduce(intent, .readerScrolled(to: next.origin), layout: next).intent
            pendingReader = false
            if Self.traces {
                print("READ_CAPTURE width=\(native.viewport.width) origin=\(native.origin) intent=\(intent)")
            }
            return nil
        }
        guard let layout, Model.layoutEvent(from: layout, to: next) != nil,
              case .reading(let anchor) = intent,
              let frame = measured.first(where: { $0.id == anchor.row }),
              let origin = Model.placement(for: intent, layout: next).origin,
              abs(origin - next.origin) > 0.5,
              next.viewport.unobscuredHeight > 0 else { return nil }
        let offset = frame.top - origin - next.viewport.topInset
        let alignmentRange = next.viewport.unobscuredHeight - frame.height
        guard abs(alignmentRange) > 0.5 else {
            assertionFailure("A viewport-height row has no UnitPoint for an arbitrary point offset.")
            return nil
        }
        if Self.traces {
            print("READ_PLACE width=\(native.viewport.width) origin=\(native.origin)->\(origin)"
                  + " intent=\(intent) offset=\(offset)")
        }
        return (anchor.row, .init(x: 0, y: offset / alignmentRange))
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
