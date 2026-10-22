import ChannelClient
import ChannelKit
import SwiftUI

/// Placeholder composer region. The Composer owner replaces this with the composer and tray.
struct ComposerArea: View {
    let store: ChannelStore
    @ViewState private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let error = store.phase.message ?? store.sendError ?? store.historyError ?? store.readError {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message the team", text: $draft, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Button("Send", systemImage: "arrow.up") {
                    let content = draft
                    Task {
                        do {
                            try await store.post(content: content)
                            if draft == content { draft = "" }
                        } catch {
                            // ChannelStore retains the error and the unsent draft remains editable.
                        }
                    }
                }
                .disabled(!store.phase.isLive || store.isSending
                          || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
