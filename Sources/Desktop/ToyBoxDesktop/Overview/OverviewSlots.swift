/// Tells one visit to a channel from the next. Each switch, including back to an earlier channel,
/// starts a new visit, so nothing kept for the last one shows again.
@MainActor
final class OverviewVisits {
    private static var count = 0
    private var channel: String?
    private var current = 0

    /// The visit showing `channel`. Calls for the same channel return the same visit.
    func visit(_ channel: String) -> Int {
        if channel != self.channel {
            self.channel = channel
            Self.count += 1
            current = Self.count
        }
        return current
    }
}

/// Row identities that let a channel switch update the rows already built instead of making new ones.
///
/// Within a visit each item keeps its slot, as it would with its own ID, so focus and VoiceOver
/// follow it as items come and go. A new visit hands the slots out again by position. Each entry's
/// `key` names its item for the visit, and rows keep that item's state in an `OverviewItemState`
/// under it, so a reused row starts fresh for the item it now shows.
@MainActor
final class OverviewSlots {
    struct Entry<Item>: Identifiable {
        let id: Int
        let key: String
        let item: Item
    }

    private let visits = OverviewVisits()
    private var visit: Int?
    private var slots: [String: Int] = [:]
    private var next = 0

    func entries<Item: Identifiable>(_ items: [Item], in channel: String) -> [Entry<Item>] where Item.ID == String {
        let visit = visits.visit(channel)
        if visit != self.visit {
            self.visit = visit
            slots = [:]
            next = 0
        }
        return items.map { item in
            let slot = slots[item.id] ?? {
                slots[item.id] = next
                next += 1
                return next - 1
            }()
            return Entry(id: slot, key: "\(visit):\(item.id)", item: item)
        }
    }
}

/// A row's state for the item one key names. Reads under any other key see the initial value, so a
/// row that `OverviewSlots` hands to another item never shows the last item's state.
struct OverviewItemState<Value> {
    private let initial: Value
    private var key: String?
    private var value: Value

    init(_ initial: Value) {
        self.initial = initial
        value = initial
    }

    subscript(key: String) -> Value {
        get { self.key == key ? value : initial }
        set {
            self.key = key
            value = newValue
        }
    }

    /// Applies a late result, such as a finished request's, only while the row still holds that
    /// item's state, so it never lands on the item the row shows now.
    mutating func update(_ key: String, _ change: (inout Value) -> Void) {
        guard self.key == key else { return }
        change(&value)
    }
}
