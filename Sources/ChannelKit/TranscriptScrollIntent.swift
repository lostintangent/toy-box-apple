import Foundation

public struct TranscriptScrollIntent: Equatable, Sendable {
    public static let followingThreshold: CGFloat = 48

    public enum Intent: Equatable, Sendable {
        case landing(String?)
        case following
        case reading
    }

    public enum Anchor: Equatable, Sendable { case top, center }

    public enum Scroll: Equatable, Sendable {
        case none
        case row(String, anchor: Anchor)
        case end(animated: Bool)
    }

    public struct Row: Equatable, Sendable {
        public var id: String
        public var sequence: Int

        public init(id: String, sequence: Int) {
            self.id = id
            self.sequence = sequence
        }
    }

    public struct VisibleRow: Equatable, Sendable {
        public var id: String
        public var sequence: Int
        public var rect: CGRect

        public init(id: String, sequence: Int, rect: CGRect) {
            self.id = id
            self.sequence = sequence
            self.rect = rect
        }
    }

    public private(set) var intent: Intent = .following

    public init() {}

    public var followsEnd: Bool { intent == .following || intent == .landing(nil) }

    public static func openingRow(after unreadAfter: Int?, in rows: [TranscriptRow]) -> String? {
        guard let unreadAfter else { return nil }
        return rows.first { $0.messages.contains { $0.sequence > unreadAfter } }?.id
    }

    public mutating func open(unreadRow: String?) -> Scroll {
        intent = .landing(unreadRow)
        return unreadRow.map { .row($0, anchor: .top) } ?? .end(animated: false)
    }

    public mutating func moved(distanceToEnd: CGFloat) {
        intent = distanceToEnd <= Self.followingThreshold ? .following : .reading
    }

    public mutating func holdReading() {
        intent = .reading
    }

    public mutating func jumpToLatest() -> Scroll {
        intent = .following
        return .end(animated: true)
    }

    public mutating func ownPostConfirmed() -> Scroll {
        intent = .following
        return .end(animated: false)
    }

    public mutating func reveal(_ id: String, availableIDs: Set<String>) -> Scroll {
        guard availableIDs.contains(id) else { return .none }
        intent = .reading
        return .row(id, anchor: .center)
    }

    public mutating func filterChanged(topVisibleSequence: Int?, rows: [Row]) -> Scroll {
        if followsEnd { return .end(animated: false) }
        guard let topVisibleSequence,
              let target = rows.first(where: { $0.sequence >= topVisibleSequence }) ?? rows.last else {
            return .none
        }
        intent = .reading
        return .row(target.id, anchor: .top)
    }

    public mutating func collapsed(_ id: String, topIsAboveView: Bool) -> Scroll {
        guard topIsAboveView else { return .none }
        intent = .reading
        return .row(id, anchor: .top)
    }

    public static func visibleRows(_ frames: [VisibleRow], in viewport: CGRect) -> [VisibleRow] {
        guard viewport.width > 0, viewport.height > 0 else { return [] }
        return frames.filter {
            $0.sequence > 0 && $0.rect.width > 0 && $0.rect.height > 0
                && $0.rect.intersects(viewport)
                && $0.rect.intersection(viewport).height >= min(24, $0.rect.height / 2)
        }.sorted {
            $0.rect.minY == $1.rect.minY ? $0.sequence < $1.sequence : $0.rect.minY < $1.rect.minY
        }
    }
}
