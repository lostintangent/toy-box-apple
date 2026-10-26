import ChannelClient
import SwiftUI

struct DeletedChannelView: View {
    let draft: ComposerDraft
    let onBack: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("This channel was deleted", systemImage: "bubble.left.and.exclamationmark.bubble.right")
        } description: {
            if draft.hasContent {
                Text("Your local draft is still available on this iPhone.")
            }
            if let error = draft.error {
                Text(error)
            }
        } actions: {
            Button("Back to Channels", action: onBack)
                .frame(minHeight: 44)
            if draft.hasContent {
                Button("Copy Draft") { DraftPasteboard.copy(draft) }
                    .frame(minHeight: 44)
            }
        }
    }
}
