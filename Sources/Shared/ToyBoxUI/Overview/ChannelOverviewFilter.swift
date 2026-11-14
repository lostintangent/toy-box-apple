import ToyBoxKit
import SwiftUI

/// A section header's toggle that narrows its rows. Both apps take its copy, identifier and rule from here.
package struct ChannelOverviewFilter {
    package let title: String
    package let identifier: String
    package let isOn: Binding<Bool>

    package static func inProgressTasks(_ isOn: Binding<Bool>) -> Self {
        .init(title: "Show Only In-Progress Tasks", identifier: "overview-tasks-in-progress-filter", isOn: isOn)
    }

    package static func workingAgents(_ isOn: Binding<Bool>) -> Self {
        .init(title: "Show Only Working Agents", identifier: "overview-team-working-filter", isOn: isOn)
    }

    /// Keeps exactly the agents whose row shows the working cue, so the filter and the pulse never disagree.
    package static func keepsWorkingAgent(presence: ChannelAgentPresence?, isAvailable: Bool) -> Bool {
        ChannelAgent.StatusLine(presence: presence, isAvailable: isAvailable).cue == .working
    }

    /// What the filtered team reads with no one kept. Offline it repeats the rows' own status rather
    /// than claiming nobody is working.
    package static func noWorkingAgentsText(isAvailable: Bool) -> String {
        isAvailable ? "No agents working" : ChannelAgent.StatusLine(presence: nil, isAvailable: false).text
    }
}
