import ChannelKit
import SwiftUI

struct ChannelActivityContent: View {
    enum Timestamp: Equatable {
        case updated, lastUpdate, completed, ended
    }

    let channelName: String
    let presentation: ChannelActivityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            summary
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var heading: some View {
        Label(channelName, systemImage: "bubble.left.and.bubble.right")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
    }

    var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(presentation.headline).font(.headline)
            if let detail = presentation.detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            time.font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var time: Text {
        let date = presentation.state.updatedAt
        return switch presentation.timestamp {
        case .updated:
            Text("Updated \(date, format: .dateTime.hour().minute())")
        case .lastUpdate:
            Text("Last update \(date, format: .dateTime.hour().minute())")
        case .completed:
            Text("Completed \(date, format: .dateTime.hour().minute())")
        case .ended:
            Text("Ended \(date, format: .dateTime.hour().minute())")
        }
    }
}

struct ChannelActivityPresentation {
    enum Phase: Equatable {
        case working, quiet, request, completed, ended, stale
    }

    let state: ChannelActivityAttributes.ContentState
    let isStale: Bool

    var phase: Phase {
        if let ending = state.ending { return ending == .completed ? .completed : .ended }
        if isStale { return .stale }
        if state.waitingRequestSequence != nil { return .request }
        return state.workingAgents.isEmpty ? .quiet : .working
    }

    var headline: String {
        switch phase {
        case .working:
            state.workingAgents.count == 1 ? "1 agent working" : "\(state.workingAgents.count) agents working"
        case .quiet: "No agents working"
        case .request: "Needs your reply"
        case .completed:
            state.tasksTotal == 1 ? "All 1 task completed" : "All \(state.tasksTotal) tasks completed"
        case .ended: "Following ended"
        case .stale: "May be out of date"
        }
    }

    var detail: String? {
        switch phase {
        case .working, .quiet, .request: "\(state.tasksDone) of \(state.tasksTotal) tasks done"
        case .completed: "Following ended"
        case .ended, .stale: nil
        }
    }

    var timestamp: ChannelActivityContent.Timestamp {
        switch phase {
        case .completed: .completed
        case .ended: .ended
        case .stale: .lastUpdate
        case .working, .quiet, .request: .updated
        }
    }

    var compactSymbol: String? {
        switch phase {
        case .working, .quiet: nil
        case .request: "questionmark.bubble"
        case .completed: "checkmark.circle"
        case .ended: "stop.circle"
        case .stale: "clock"
        }
    }

    var minimalSymbol: String {
        compactSymbol ?? "bubble.left.and.bubble.right"
    }

    var requestSequence: Int? {
        phase == .request ? state.waitingRequestSequence : nil
    }
}
