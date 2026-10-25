import AppKit
import ChannelKit

struct TranscriptNativeLayout: Equatable {
    let viewport: TranscriptScrollModel.Viewport
    let origin: CGFloat
    let documentEnd: CGFloat
    let documentWidth: CGFloat

    var hasConstrainedOrigin: Bool {
        let minimum = -viewport.topInset
        let maximum = max(minimum, documentEnd - viewport.height + viewport.bottomInset)
        return origin >= minimum - 0.5 && origin <= maximum + 0.5
    }
}

extension TranscriptNativeLayout {
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
final class TranscriptReader {
    typealias Model = TranscriptScrollModel
    private(set) var intent: Model.Intent = .following
    private var previousNative: TranscriptNativeLayout?
    private var pendingReaderOrigin: CGFloat?
    private var projectedRows: [TranscriptRow] = []
    private var expandedIDs: Set<String> = []
    private var rows: [Model.RowIdentity] = []
    private var identities: [String: Model.RowIdentity] = [:]

    var isFollowing: Bool {
        guard pendingReaderOrigin == nil else { return false }
        if case .following = intent { return true }
        return false
    }

    func followLatest() {
        intent = .following
        pendingReaderOrigin = nil
    }

    func receive(_ native: TranscriptNativeLayout, frames: [String: TranscriptMessageFrame],
                 canonicalRows: [TranscriptRow], expandedIDs: Set<String>, historyStart: Int,
                 allowsReader: Bool, isTranscriptWrite: Bool) {
        defer { previousNative = native }
        if let previousNative, previousNative.hasConstrainedOrigin, allowsReader, !isTranscriptWrite,
           previousNative.viewport == native.viewport,
           previousNative.documentEnd == native.documentEnd,
           previousNative.documentWidth == native.documentWidth,
           abs(previousNative.origin - native.origin) > 0.5 {
            pendingReaderOrigin = native.origin
        }
        guard allowsReader, let origin = pendingReaderOrigin, abs(origin - native.origin) <= 0.5 else { return }
        if projectedRows != canonicalRows || self.expandedIDs != expandedIDs {
            projectedRows = canonicalRows
            self.expandedIDs = expandedIDs
            rows = transcriptScrollIdentities(canonicalRows, expandedMessageIds: expandedIDs)
            identities = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        }
        let measured = frames.compactMap { id, frame -> Model.RowFrame? in
            guard frame.historyStart == historyStart, let identity = identities[id] else { return nil }
            let top = TranscriptCoordinates.contentTopPadding + frame.contentTop
            guard top >= 0, top + frame.rect.height <= native.documentEnd + 0.5,
                  abs(frame.rect.minY - (top - native.origin - native.viewport.topInset)) <= 0.5 else { return nil }
            return .init(id: id, order: identity.order, top: top, height: frame.rect.height,
                         isAnchorable: identity.isAnchorable)
        }
        let layout = Model.Layout(rows: rows, frames: measured, viewport: native.viewport,
                                  origin: native.origin, documentEnd: native.documentEnd)
        guard Model.distanceToEnd(in: layout) <= Model.followingThreshold
                || Model.firstRowStartingInView(native.origin, rows: measured, viewport: native.viewport) != nil
        else { return }
        intent = Model.reduce(intent, .readerScrolled(to: native.origin), layout: layout).intent
        pendingReaderOrigin = nil
        transcriptScrollTrace("reader.capture native=\(native.origin) intent=\(intent)")
    }
}
