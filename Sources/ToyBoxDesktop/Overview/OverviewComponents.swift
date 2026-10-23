import AppKit
import SwiftUI

/// The inspector's collapsible sections, persisted per window scene rather than per channel.
enum OverviewSectionID: String, CaseIterable {
    case team, tasks, artifacts, routines

    var title: String {
        switch self {
        case .team: "Team"
        case .tasks: "Tasks"
        case .artifacts: "Artifacts"
        case .routines: "Routines"
        }
    }

    static func decode(_ raw: String) -> Set<OverviewSectionID> {
        Set(raw.split(separator: ",").compactMap { OverviewSectionID(rawValue: String($0)) })
    }

    static func encode(_ sections: Set<OverviewSectionID>) -> String {
        allCases.filter(sections.contains).map(\.rawValue).joined(separator: ",")
    }
}

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

/// A divider, then a Finder-style header whose chevron appears on hover or focus and stays while collapsed.
struct OverviewSection<Trailing: View, Content: View>: View {
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: OverviewSectionID
    let count: String
    var accessibilityCount: String?
    @Binding var collapsed: Set<OverviewSectionID>
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    @ViewState private var isHovering = false
    @FocusState private var isFocused: Bool

    private var isCollapsed: Bool { collapsed.contains(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 2)
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Text(id.title).font(.system(size: 13 * textScale, weight: .bold))
                    Text(count)
                        .font(.system(size: 13 * textScale).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    trailing()
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .opacity(isCollapsed || isHovering || isFocused ? 1 : 0)
                }
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .onHover { isHovering = $0 }
            .padding(.top, 8)
            .help(isCollapsed ? "Show \(id.title)" : "Hide \(id.title)")
            .accessibilityLabel("\(id.title), \(accessibilityCount ?? count)")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityAddTraits(.isHeader)
            if !isCollapsed {
                content().padding(.top, 4)
            }
        }
        .padding(.bottom, 12)
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            if isCollapsed { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }
}

extension OverviewSection where Trailing == EmptyView {
    init(id: OverviewSectionID, count: String, accessibilityCount: String? = nil,
         collapsed: Binding<Set<OverviewSectionID>>, @ViewBuilder content: @escaping () -> Content) {
        self.init(id: id, count: count, accessibilityCount: accessibilityCount, collapsed: collapsed,
                  trailing: { EmptyView() }, content: content)
    }
}

/// One secondary sentence for a section that has nothing in it yet.
struct OverviewEmptyText: View {
    @Environment(\.channelTextScale) private var textScale
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12 * textScale))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }
}

/// The borderless `ellipsis.circle` actions menu that rows reveal on hover or keyboard focus.
///
/// Its pop-up button is the costliest part of a row to create, so a hidden menu is an empty slot of
/// the same size. Under Keyboard navigation hidden menus
/// stay in the key view loop, so they're created up front and Shift-Tab still reaches them.
/// The button keeps its own smaller size at the slot's trailing edge, where it has always sat.
struct OverviewRowMenu<Items: View>: View {
    static var size: CGFloat { 28 }

    let title: String
    let isVisible: Bool
    @ViewBuilder var items: () -> Items

    var body: some View {
        if isVisible || NSApplication.shared.isFullKeyboardAccessEnabled {
            menu
        } else {
            Color.clear.frame(width: Self.size, height: Self.size)
        }
    }

    private var menu: some View {
        Menu(content: items) {
            Label(title, systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: Self.size, height: Self.size, alignment: .trailing)
        .help(title)
        .accessibilityLabel(title)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
    }
}

/// A title with its disclosure trailing inline, as macOS sidebar section headers do: the title,
/// an optional count such as "3/4", then the chevron, as one wrapping text. Non-breaking spaces
/// carry the chevron with the title's last word, so it never wraps onto a line of its own.
enum OverviewInlineDisclosure {
    static func line(_ title: Text, isExpanded: Bool, count: String? = nil, textScale: CGFloat) -> Text {
        let gap = Text(verbatim: "\u{00A0}\u{00A0}").font(.system(size: 13 * textScale))
        let chevron = Text(Image(systemName: isExpanded ? "chevron.down" : "chevron.right"))
            .font(.system(size: 9 * textScale, weight: .bold))
            .foregroundStyle(.secondary)
        guard let count else { return title + gap + chevron }
        let counted = Text(verbatim: "\(count)\u{00A0}")
            .font(.system(size: 11 * textScale).monospacedDigit())
            .foregroundStyle(.secondary)
        return title + gap + counted + chevron
    }
}

/// A compact About property: an 18-point symbol column, 6 points, then a 12-point value.
struct OverviewPropertyRow<Value: View>: View {
    @Environment(\.channelTextScale) private var textScale
    let symbol: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13 * textScale))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            value().font(.system(size: 12 * textScale))
        }
        .frame(minHeight: 22)
    }
}
