import ChannelClient
import SwiftUI

/// A pending send's delivery label for its row. A quick send shows none, so confirming it changes
/// nothing on screen. Only a send still going after `slowAfter` says so. A failed one shows no text,
/// just its row's red wash and Retry.
public struct TranscriptDeliveryLabel<Content: View>: View {
    let phase: ChannelSendPhase
    let slowAfter: Duration
    let content: (String?) -> Content
    @ViewState private var isSlow = false

    public init(phase: ChannelSendPhase, slowAfter: Duration = .seconds(1),
                @ViewBuilder content: @escaping (String?) -> Content) {
        self.phase = phase
        self.slowAfter = slowAfter
        self.content = content
    }

    private var label: String? {
        switch phase {
        case .sending: isSlow ? phase.label : nil
        case .confirmed, .notSent, .deliveryNotConfirmed: nil
        }
    }

    public var body: some View {
        content(label)
            .task(id: phase) {
                isSlow = false
                guard phase == .sending else { return }
                try? await Task.sleep(for: slowAfter)
                if !Task.isCancelled { isSlow = true }
            }
    }
}
