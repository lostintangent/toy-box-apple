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
            case .replied: continue
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

    /// Sets a request's row state. A replied row keeps it until the next opening, so nothing slides out
    /// from under the pointer.
    mutating func record(_ channelID: String, _ status: Request.Status) {
        guard let index = requests.firstIndex(where: { $0.id == channelID }) else { return }
        requests[index].state = status
    }

    struct Request: Equatable, Identifiable {
        enum Status: Equatable {
            case waiting, answered, newerRequest, replied

            var notice: String? {
                switch self {
                case .waiting: nil
                case .answered: "This request was answered elsewhere"
                case .newerRequest: "A newer request is waiting"
                case .replied: "Replied"
                }
            }

            var symbol: String {
                switch self {
                case .replied: "checkmark.circle"
                case .waiting, .answered, .newerRequest: "info.circle"
                }
            }
        }

        var item: MenuBarStatus.Item
        var state: Status = .waiting
        var id: String { item.id }
        var canReply: Bool { state == .waiting && item.quote != nil && item.agent != nil && item.sequence != nil }
        var canChoose: Bool { state == .waiting && !item.replies.isEmpty }

        /// The choices this row still offers. Choosing one makes the row Replied, and a request the
        /// outbox answers leaves the waiting list until a Not sent answer brings it back with its
        /// choices. They disable while the catalog can't connect, as every Send does.
        func choices(isConnected: Bool) -> TranscriptRequestChoices? {
            guard canChoose, let sequence = item.sequence else { return nil }
            return TranscriptRequestChoices(sequence: sequence, labels: item.replies, isConnected: isConnected)
        }
    }
}
