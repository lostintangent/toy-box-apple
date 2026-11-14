import ToyBoxClient
import SwiftUI

/// The channel window's placeholder while a Handoff channel opens, or when it can't be found.
public struct ChannelHandoffContent: View {
    private let phase: ChannelHandoffNavigation.Phase
    private let showChannels: () -> Void

    public init(phase: ChannelHandoffNavigation.Phase, showChannels: @escaping () -> Void) {
        self.phase = phase
        self.showChannels = showChannels
    }

    public var body: some View {
        if phase == .opening {
            ProgressView("Opening channel…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Channel unavailable", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("This channel isn't available.")
            } actions: {
                Button("Show Channels", action: showChannels)
                    #if os(macOS)
                    .keyboardShortcut(.defaultAction)
                    #endif
            }
        }
    }
}
