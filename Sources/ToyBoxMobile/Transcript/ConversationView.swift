import ChannelClient
import SwiftUI

struct ConversationView: View { let store: ChannelStore; var body: some View { ContentUnavailableView("Conversation", systemImage: "bubble.left.and.bubble.right", description: Text("Conversation is being built.")) } }
