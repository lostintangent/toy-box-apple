import ChannelKit
import SwiftUI

package enum ChannelOverviewSummary {
    case team(Int?), tasks(ChannelTask.Progress?), artifacts(Int?), routines(Int?)

    package var title: String {
        switch self {
        case .team: "Team Members"
        case .tasks: "Tasks"
        case .artifacts: "Artifacts"
        case .routines: "Routines"
        }
    }

    package var count: String {
        switch self {
        case .tasks(let progress):
            guard let progress else { return "Unavailable" }
            return progress.total == 0 ? "0" : "\(progress.done)/\(progress.total)"
        case .team(let count), .artifacts(let count), .routines(let count):
            return count.map(String.init) ?? "Unavailable"
        }
    }

    package var spoken: String {
        let detail: String
        switch self {
        case .tasks(let progress):
            guard let progress else { return "\(title), count unavailable" }
            detail = progress.total == 0 ? "no tasks"
                : "\(progress.done) of \(progress.total) top-level \(progress.total == 1 ? "task" : "tasks") complete"
        case .team(let count):
            guard let count else { return "\(title), count unavailable" }
            detail = "\(count) \(count == 1 ? "agent" : "agents")"
        case .artifacts(let count):
            guard let count else { return "\(title), count unavailable" }
            detail = "\(count) shared \(count == 1 ? "artifact" : "artifacts")"
        case .routines(let count):
            guard let count else { return "\(title), count unavailable" }
            detail = "\(count) \(count == 1 ? "routine" : "routines")"
        }
        return "\(title), \(detail)"
    }
}
