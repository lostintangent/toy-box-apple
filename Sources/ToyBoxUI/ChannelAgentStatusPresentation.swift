import ChannelKit
import SwiftUI

package struct ChannelAgentStatusPresentation: Equatable, Sendable {
    package enum Cue: Equatable, Sendable { case none, working, waiting }

    package let text: String
    package let spoken: String
    package let cue: Cue

    package var textColor: Color { cue == .working ? .primary.opacity(0.85) : ChannelInk.secondary }

    package init(presence: ChannelAgentPresence?, isLive: Bool) {
        guard isLive else {
            text = "Status unavailable while disconnected"
            spoken = text
            cue = .none
            return
        }
        guard let presence else {
            text = "Status unavailable"
            spoken = text
            cue = .none
            return
        }
        let message = presence.text.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        switch presence.state {
        case "working":
            text = message ?? "Working"
            spoken = text.lowercased().hasPrefix("working") ? text : "Working, \(text)"
            cue = .working
        case "waiting":
            if let message {
                text = message.lowercased().hasPrefix("waiting") ? message : "Waiting for \(message)"
            } else {
                text = "Waiting"
            }
            spoken = text
            cue = .waiting
        default:
            text = "Idle"
            spoken = text
            cue = .none
        }
    }

    package static func waitingCue(in scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 244.0 / 255, green: 190.0 / 255, blue: 102.0 / 255, opacity: 1)
            : Color(.sRGB, red: 154.0 / 255, green: 103.0 / 255, blue: 0, opacity: 1)
    }
}
