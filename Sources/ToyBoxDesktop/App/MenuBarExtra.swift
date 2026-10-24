import AppKit
import ChannelKit
import Observation
import SwiftUI

/// Whether the menu bar extra is in the menu bar. When Active shows it as soon as anything is
/// active, keeps it for a while after the last activity ends, and never removes it while a menu
/// is open, so it can't vanish under the pointer.
@MainActor @Observable
final class MenuBarPresence {
    private(set) var isInserted = false
    @ObservationIgnored var visibility: MenuBarVisibility = .whenActive {
        didSet { if visibility != oldValue { settle() } }
    }
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var lingers = false
    @ObservationIgnored private var isMenuOpen = false
    /// The countdown after activity ends, awaitable so tests needn't race it.
    @ObservationIgnored private(set) var linger: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let lingerDuration: Duration

    init(linger: Duration = MenuBarVisibility.linger) {
        lingerDuration = linger
        for (name, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTracking(open) }
            })
        }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func update(isActive: Bool) {
        guard isActive != self.isActive else { return }
        self.isActive = isActive
        linger?.cancel()
        lingers = !isActive && isInserted
        if lingers {
            linger = Task { [weak self, lingerDuration] in
                try? await Task.sleep(for: lingerDuration)
                guard !Task.isCancelled, let self else { return }
                self.lingers = false
                self.settle()
            }
        }
        settle()
    }

    func menuTracking(_ open: Bool) {
        isMenuOpen = open
        settle()
    }

    private func settle() {
        let inserted = switch visibility {
        case .always: true
        case .never: false
        case .whenActive: isActive || lingers || (isInserted && isMenuOpen)
        }
        if inserted != isInserted { isInserted = inserted }
    }
}

/// The status item: one template symbol, never animated in place and never colored.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let status = model.menuBarStatus
        Label {
            Text(MenuBarAccessibility.title)
        } icon: {
            // The status item takes its accessibility title from the symbol's label.
            Image(systemName: status.symbol)
                .accessibilityLabel(MenuBarAccessibility.title)
        }
        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        .task(id: status.accessibilityValue) { await MenuBarAccessibility.apply(status.accessibilityValue) }
    }
}

/// SwiftUI doesn't carry a menu bar extra label's accessibility value to its status item, so
/// VoiceOver would hear the app's name and nothing of the team. The value goes on the item's
/// button instead.
@MainActor
enum MenuBarAccessibility {
    static let title = "Toy Box Desktop"

    static func apply(_ value: String) async {
        // The scene inserts the button just after the label first renders.
        for _ in 0..<20 {
            let buttons = statusButtons()
            if !buttons.isEmpty {
                for button in buttons where button.accessibilityValue() as? String != value {
                    button.setAccessibilityValue(value)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
    }

    private static func statusButtons() -> [NSStatusBarButton] {
        func buttons(in view: NSView) -> [NSStatusBarButton] {
            if let button = view as? NSStatusBarButton { return [button] }
            return view.subviews.flatMap(buttons)
        }
        return NSApp.windows.filter { $0.level == .statusBar }.compactMap(\.contentView).flatMap(buttons)
    }
}

/// The menu bar extra's menu. It reads the catalog as it last polled and never refreshes on open,
/// so items don't move under the pointer.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let status = model.menuBarStatus
        if let empty = status.emptyText {
            Button(empty) {}.disabled(true)
        }
        section("Waiting for You", status.waitingSection, revealsRequest: true)
        section("Working", status.workingSection, revealsRequest: false)
        Divider()
        QuickAskMenuButton(controller: model.quickAsk)
        Button("Open Toy Box Desktop") { model.activate(channelID: nil) }
        Button("Settings\u{2026}") {
            NSApplication.shared.activate()
            openSettings()
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ section: MenuBarStatus.Section, revealsRequest: Bool) -> some View {
        if !section.items.isEmpty {
            Section(title) {
                ForEach(section.items) { item in
                    Button {
                        model.activate(channelID: item.id, sequence: revealsRequest ? item.sequence : nil)
                    } label: {
                        // A menu renders a label's icon only in the title-and-icon style, and a
                        // subtitle only as a Text beside the label rather than inside its title.
                        if let image = item.agent.flatMap(MenuBarAvatars.image) {
                            Label { Text(item.name) } icon: { Image(nsImage: image) }
                                .labelStyle(.titleAndIcon)
                        } else {
                            Text(item.name)
                        }
                        Text(item.subtitle)
                    }
                }
                if section.overflow > 0 {
                    Button(MenuBarStatus.moreChannels(section.overflow)) { model.activate(channelID: nil) }
                }
            }
        }
    }
}

/// Agents' avatars as 16-point menu item images, drawn by the same view as everywhere else.
@MainActor
enum MenuBarAvatars {
    private static var images: [String: NSImage] = [:]

    static func image(_ agent: ChannelAgent) -> NSImage? {
        let key = [agent.id, agent.name, agent.avatar?.mark ?? "", agent.avatar?.color ?? "",
                   agent.deleted == true ? "deleted" : ""].joined(separator: "\n")
        if let image = images[key] { return image }
        let renderer = ImageRenderer(content: AgentAvatarView(agent: agent, size: 16))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 16, height: 16))
        images[key] = image
        return image
    }
}
