import ChannelClient
import SwiftUI

/// A pending send's delivery label for its row. A quick send shows none, so confirming it changes
/// nothing on screen. Only a send still going after `slowAfter` says so. A failed one shows no text,
/// just its row's red wash and Retry.
public struct TranscriptDeliveryLabel<Content: View>: View {
    let state: ChannelOutbox.State
    let slowAfter: Duration
    let content: (String?) -> Content
    @ViewState private var isSlow = false

    public init(state: ChannelOutbox.State, slowAfter: Duration = .seconds(1),
                @ViewBuilder content: @escaping (String?) -> Content) {
        self.state = state
        self.slowAfter = slowAfter
        self.content = content
    }

    private var label: String? { state == .sending && isSlow ? "Sending" : nil }

    public var body: some View {
        content(label)
            .task(id: state) {
                isSlow = false
                guard state == .sending else { return }
                try? await Task.sleep(for: slowAfter)
                if !Task.isCancelled { isSlow = true }
            }
    }
}

extension ChannelStore {
    /// The messages the outbox still holds for this channel, Sending or Not sent, which the
    /// transcript shows below the server's.
    @MainActor public var sending: [ChannelOutbox.Message] { outbox?.messages(in: id) ?? [] }
}
