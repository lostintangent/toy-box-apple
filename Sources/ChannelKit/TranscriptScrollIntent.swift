import Foundation

public struct TranscriptScrollIntent: Equatable, Sendable {
    public enum Intent: Equatable, Sendable {
        case landing(String?)
        case following
        case reading
    }

    public enum Scroll: Equatable, Sendable {
        case row(String)
        case end
    }

    public private(set) var intent: Intent = .following

    public init() {}

    public var followsEnd: Bool { intent == .following || intent == .landing(nil) }

    public mutating func open(unreadRow: String?) -> Scroll {
        intent = .landing(unreadRow)
        return unreadRow.map(Scroll.row) ?? .end
    }

    public mutating func moved(distanceToEnd: CGFloat) {
        intent = distanceToEnd <= 48 ? .following : .reading
    }

    public mutating func jumpToLatest() -> Scroll {
        intent = .following
        return .end
    }
}
