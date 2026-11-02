import ChannelClient
import Foundation
import ToyBoxUI

/// An open inbox keeps its request order and answered rows until the next opening.
struct MenuBarInboxRequests: Equatable {
    private(set) var requests: [Request] = []

    init(status: MenuBarStatus = .init()) {
        requests = status.waiting.map { Request(item: $0) }
    }

    mutating func update(_ status: MenuBarStatus) {
        let current = Dictionary(status.waiting.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in requests.indices {
            switch requests[index].state {
            case .sent, .sending, .notSent: continue
            case .waiting, .answered, .newerRequest: break
            }
            let previous = requests[index].item
            guard let item = current[previous.id] else {
                requests[index].state = .answered
                continue
            }
            if item.sequence == previous.sequence {
                requests[index].item = item
                requests[index].state = .waiting
            } else {
                requests[index].state = .newerRequest
            }
        }
        let retained = Set(requests.map(\.id))
        requests += status.waiting.filter { !retained.contains($0.id) }.map { Request(item: $0) }
    }

    /// Sets a request's row state. A row that's sending or not sent keeps it until the next opening.
    mutating func record(_ channelID: String, _ status: Request.Status) {
        guard let index = requests.firstIndex(where: { $0.id == channelID }) else { return }
        requests[index].state = status
    }

    struct Request: Equatable, Identifiable {
        enum Status: Equatable {
            case waiting, answered, newerRequest, sending, sent, notSent

            var notice: String? {
                switch self {
                case .waiting: nil
                case .answered: "This request was answered elsewhere"
                case .newerRequest: "A newer request is waiting"
                case .sending: "Sending reply…"
                case .sent: "Reply sent"
                case .notSent: "Reply not sent. Open the channel to send it again."
                }
            }

            var symbol: String {
                switch self {
                case .sent: "checkmark.circle"
                case .notSent: "exclamationmark.circle"
                case .sending: "paperplane"
                case .waiting, .answered, .newerRequest: "info.circle"
                }
            }
        }

        var item: MenuBarStatus.Item
        var state: Status = .waiting
        var id: String { item.id }
        var canReply: Bool { state == .waiting && item.quote != nil && item.agent != nil && item.sequence != nil }
        var canChoose: Bool { state == .waiting && !item.replies.isEmpty }

        /// The choices this row still offers. The outbox takes a choice off the row for good, as the
        /// transcript does. The inbox sends in the background, so a disconnected channel doesn't disable them.
        func choices(attempts: [ChannelSendAttempt]) -> [String] {
            guard canChoose, let sequence = item.sequence else { return [] }
            return TranscriptRequestChoices(sequence: sequence, labels: item.replies, attempts: attempts,
                                            isConnected: true)?.labels ?? []
        }
    }
}
