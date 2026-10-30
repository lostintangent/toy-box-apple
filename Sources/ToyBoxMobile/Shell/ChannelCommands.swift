import ChannelClient
import ChannelKit
import SwiftUI

@MainActor
struct WindowCommandActions {
    var messageView: TranscriptView
    var sidebarVisible: Bool
    var inspectorVisible: Bool
    var findChannel: () -> Void
    var findInChannel: (() -> Void)?
    var findNext: ((Int) -> Void)?
    var newChannel: (() -> Void)?
    var openInToyBox: (() -> Void)?
    var toggleSidebar: (() -> Void)?
    var toggleInspector: (() -> Void)?
    var setMessageView: ((TranscriptView) -> Void)?
    var refresh: () -> Void
    var nextChannel: ((ChannelNavigation.Direction) -> Void)?
    var nextAttention: (() -> Void)?
    var focusComposer: (() -> Void)?
    var jumpToLatest: (() -> Void)?
    var revealRequest: (() -> Void)?
}

private struct ChannelCommandsKey: FocusedValueKey {
    typealias Value = WindowCommandActions
}

private struct ChannelListFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var channelCommands: WindowCommandActions? {
        get { self[ChannelCommandsKey.self] }
        set { self[ChannelCommandsKey.self] = newValue }
    }

    var channelListFocused: Bool? {
        get { self[ChannelListFocusKey.self] }
        set { self[ChannelListFocusKey.self] = newValue }
    }
}

struct ChannelCommands: Commands {
    @FocusedValue(\.channelCommands) private var actions
    @FocusedValue(\.channelListFocused) private var channelListFocused

    private var findsChannels: Bool { channelListFocused == true || actions?.findInChannel == nil }

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
            Button(findsChannels ? "Find Channel" : "Find in Conversation") {
                if findsChannels { actions?.findChannel() }
                else { actions?.findInChannel?() }
            }
                .keyboardShortcut("f")
                .disabled(actions == nil || (!findsChannels && actions?.findInChannel == nil))
            Button("Find Next") { actions?.findNext?(1) }
                .keyboardShortcut("g")
                .disabled(actions?.findNext == nil)
            Button("Find Previous") { actions?.findNext?(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions?.findNext == nil)
            Divider()
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
                Label("All Messages", systemImage: "bubble.left.and.bubble.right").tag(TranscriptView.all).keyboardShortcut("1")
                Label("Your Messages", systemImage: "person").tag(TranscriptView.yours).keyboardShortcut("2")
            }
            .disabled(actions?.setMessageView == nil)
            Button("Refresh") { actions?.refresh() }
                .keyboardShortcut("r")
                .disabled(actions == nil)
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
