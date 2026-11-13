import SwiftUI

/// A new channel's conversation before its first message, while its lead gets the channel ready.
public struct TranscriptEmptyChannel: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView {
            Label {
                Text("The lead is getting your new channel ready")
            } icon: {
                Image(systemName: "ellipsis.bubble").symbolEffect(.variableColor.iterative)
            }
        } description: {
            Text("Send a message or type @ to add an agent.")
        }
    }
}
