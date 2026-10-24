import Foundation

/// An open inbox keeps its request order and answered rows until the next opening.
struct MenuBarInboxState: Equatable {
    enum RequestState: Equatable {
        case waiting, answered, newerRequest, sent

        var notice: String? {
            switch self {
            case .waiting: nil
            case .answered: "This request was answered elsewhere"
            case .newerRequest: "A newer request is waiting"
            case .sent: "Reply sent"
            }
        }
    }

    struct Request: Equatable, Identifiable {
        var item: MenuBarStatus.Item
        var state: RequestState = .waiting
        var id: String { item.id }
        var canReply: Bool { state == .waiting && item.quote != nil && item.agent != nil && item.sequence != nil }
    }

    private(set) var requests: [Request] = []

    init(status: MenuBarStatus = .init()) {
        requests = status.waiting.map { Request(item: $0) }
    }

    mutating func update(_ status: MenuBarStatus) {
        let current = Dictionary(status.waiting.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in requests.indices {
            guard requests[index].state != .sent else { continue }
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

    mutating func confirmed(_ channelID: String) {
        guard let index = requests.firstIndex(where: { $0.id == channelID }) else { return }
        requests[index].state = .sent
    }
}
