import ChannelClient
import ChannelKit
import SwiftUI

// Keep focus publication stable across native inspector layout passes.
enum ChannelRefreshTarget: Equatable {
    case catalog(AppModel)
    case channel(ChannelStore)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.catalog(let lhs), .catalog(let rhs)): lhs === rhs
        case (.channel(let lhs), .channel(let rhs)): lhs === rhs
        default: false
        }
    }

    @MainActor @discardableResult
    func perform() -> Task<Void, Never>? {
        switch self {
        case .catalog(let model): return Task { await model.refreshCatalog() }
        case .channel(let store):
            store.reconnect()
            return nil
        }
    }
}

@MainActor
struct WindowCommandActions {
    var messageView: TranscriptView
    var sidebarVisible: Bool
    var inspectorVisible: Bool
    var findChannel: () -> Void
    var newChannel: (() -> Void)?
    var openInToyBox: (() -> Void)?
    var toggleSidebar: (() -> Void)?
    var toggleInspector: (() -> Void)?
    var setMessageView: ((TranscriptView) -> Void)?
    var refresh: (() -> Void)?
    var nextChannel: ((ChannelNavigation.Direction) -> Void)?
    var nextAttention: (() -> Void)?
    var focusComposer: (() -> Void)?
    var jumpToLatest: (() -> Void)?
    var revealRequest: (() -> Void)?
}

private struct ChannelCommandsKey: FocusedValueKey {
    typealias Value = WindowCommandActions
}

private struct ChannelRefreshKey: FocusedValueKey {
    typealias Value = ChannelRefreshTarget
}

extension FocusedValues {
    var channelCommands: WindowCommandActions? {
        get { self[ChannelCommandsKey.self] }
        set { self[ChannelCommandsKey.self] = newValue }
    }

    var channelRefresh: ChannelRefreshTarget? {
        get { self[ChannelRefreshKey.self] }
        set { self[ChannelRefreshKey.self] = newValue }
    }
}

struct ChannelCommands: Commands {
    @FocusedValue(\.channelCommands) private var actions
    @FocusedValue(\.channelRefresh) private var focusedRefresh

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Channel") { actions?.newChannel?() }
                .keyboardShortcut("n")
                .disabled(actions?.newChannel == nil)
            Button("Open in Toy Box") { actions?.openInToyBox?() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions?.openInToyBox == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find Channel") { actions?.findChannel() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(actions == nil)
        }
        CommandGroup(before: .toolbar) {
            Button(actions?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") { actions?.toggleSidebar?() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(actions?.toggleSidebar == nil)
            Button(actions?.inspectorVisible == true ? "Hide Overview" : "Show Overview") { actions?.toggleInspector?() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(actions?.toggleInspector == nil)
            Picker("Message View", selection: Binding(
                get: { actions?.messageView ?? .all },
                set: { actions?.setMessageView?($0) }
            )) {
                Text("All Messages").tag(TranscriptView.all).keyboardShortcut("1")
                Text("Your Messages").tag(TranscriptView.yours).keyboardShortcut("2")
            }
            .disabled(actions?.setMessageView == nil)
            Button("Refresh") {
                if let focusedRefresh { focusedRefresh.perform() }
                else { actions?.refresh?() }
            }
                .keyboardShortcut("r")
                .disabled(actions == nil || (focusedRefresh == nil && actions?.refresh == nil))
        }
        CommandMenu("Channel") {
            Button("Next Channel") { actions?.nextChannel?(.next) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(actions?.nextChannel == nil)
            Button("Previous Channel") { actions?.nextChannel?(.previous) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(actions?.nextChannel == nil)
            Button("Next Channel Needing Attention") { actions?.nextAttention?() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(actions?.nextAttention == nil)
            Divider()
            Button("Focus Composer") { actions?.focusComposer?() }
                .keyboardShortcut("l")
                .disabled(actions?.focusComposer == nil)
            Button("Jump to Latest") { actions?.jumpToLatest?() }
                .keyboardShortcut("j")
                .disabled(actions?.jumpToLatest == nil)
            Button("Jump to Input Needed") { actions?.revealRequest?() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(actions?.revealRequest == nil)
        }
    }
}
