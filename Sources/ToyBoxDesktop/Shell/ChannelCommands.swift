import ChannelKit
import SwiftUI

/// The open image's zoom, which takes over the Text Size keys while this window shows an image.
struct ImageZoomActions {
    var canZoomIn: Bool
    var canZoomOut: Bool
    var isActualSize: Bool
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var actualSize: () -> Void
}

struct WindowCommandActions {
    var hasChannel: Bool
    var hasRequest: Bool
    var sidebarVisible: Bool
    var inspectorVisible: Bool
    var messageView: TranscriptView
    /// Non-nil while the image viewer covers the conversation, which disables the commands that
    /// act on what's underneath.
    var imageZoom: ImageZoomActions? = nil
    var newChannel: () -> Void
    var openNewWindow: () -> Void
    var openInToyBox: () -> Void
    /// Nil unless the selected channel's folder is on this Mac.
    var openFolder: (() -> Void)?
    var findChannel: () -> Void
    var toggleSidebar: () -> Void
    var toggleInspector: () -> Void
    var setMessageView: (TranscriptView) -> Void
    var refresh: () -> Void
    var nextChannel: (Int) -> Void
    var nextAttention: () -> Void
    var focusComposer: () -> Void
    var jumpToLatest: () -> Void
    var revealRequest: () -> Void
}

private struct ChannelCommandsKey: FocusedValueKey {
    typealias Value = WindowCommandActions
}

extension FocusedValues {
    var channelCommands: WindowCommandActions? {
        get { self[ChannelCommandsKey.self] }
        set { self[ChannelCommandsKey.self] = newValue }
    }
}

struct ChannelCommands: Commands {
    let model: AppModel
    @FocusedValue(\.channelCommands) private var actions
    @AppStorage("textScale") private var textScale = 1.0
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.updates.checkForUpdates() }
                .disabled(!model.updates.canCheckForUpdates)
            Divider()
            QuickAskMenuButton(controller: model.quickAsk)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Channel…") {
                if let actions { actions.newChannel() }
                else {
                    model.newChannelRequest = UUID()
                    openWindow(id: "channels")
                }
            }
                .keyboardShortcut("n")
                .disabled(model.api == nil)
            Button("Open Channel in New Window") { actions?.openNewWindow() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.hasChannel != true)
            Button("Open in Toy Box") { actions?.openInToyBox() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions?.hasChannel != true)
            Button("Open Folder in Finder") { actions?.openFolder?() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(actions?.openFolder == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find Channel") { actions?.findChannel() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(actions == nil)
        }
        CommandGroup(before: .toolbar) {
            Button(actions?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") { actions?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button(actions?.inspectorVisible == false ? "Show Overview" : "Hide Overview") { actions?.toggleInspector() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!hasConversation)
            Divider()
            Picker("Message View", selection: Binding(
                get: { actions?.messageView ?? .all },
                set: { actions?.setMessageView($0) }
            )) {
                Text("All Messages").tag(TranscriptView.all).keyboardShortcut("1")
                Text("Your Messages").tag(TranscriptView.yours).keyboardShortcut("2")
            }
            .disabled(!hasConversation)
            Button("Refresh") { actions?.refresh() }.keyboardShortcut("r").disabled(actions == nil)
            // AppKit matches a "+" equivalent for both Command-= and Command-Shift-=.
            if let zoom = actions?.imageZoom {
                Button("Actual Size") { zoom.actualSize() }.keyboardShortcut("0").disabled(zoom.isActualSize)
                Button("Zoom In") { zoom.zoomIn() }.keyboardShortcut("+").disabled(!zoom.canZoomIn)
                Button("Zoom Out") { zoom.zoomOut() }.keyboardShortcut("-").disabled(!zoom.canZoomOut)
            } else {
                Menu("Text Size") {
                    Button("Larger") { textScale = min(1.4, textScale + 0.1) }
                        .keyboardShortcut("+").disabled(textScale >= 1.4)
                    Button("Smaller") { textScale = max(0.85, textScale - 0.1) }
                        .keyboardShortcut("-").disabled(textScale <= 0.85)
                    Button("Default") { textScale = 1 }.keyboardShortcut("0")
                }
            }
        }
        CommandMenu("Channel") {
            Button("Next Channel") { actions?.nextChannel(1) }
                .keyboardShortcut(.tab, modifiers: .control).disabled(actions == nil)
            Button("Previous Channel") { actions?.nextChannel(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(actions == nil)
            Button("Next Channel Needing Attention") { actions?.nextAttention() }
                .keyboardShortcut("u", modifiers: [.command, .shift]).disabled(actions == nil)
            Divider()
            Button("Focus Composer") { actions?.focusComposer() }
                .keyboardShortcut("l").disabled(!hasConversation)
            Button("Jump to Latest") { actions?.jumpToLatest() }
                .keyboardShortcut("j").disabled(!hasConversation)
            Button("Jump to Input Needed") { actions?.revealRequest() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(actions?.hasRequest != true || actions?.imageZoom != nil)
        }
    }

    /// A channel's conversation is on screen rather than under the image viewer.
    private var hasConversation: Bool { actions?.hasChannel == true && actions?.imageZoom == nil }
}
