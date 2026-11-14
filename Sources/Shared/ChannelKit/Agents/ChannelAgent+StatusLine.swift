import Foundation

extension ChannelAgent {
    package struct StatusLine: Equatable, Sendable {
        package enum Cue: Equatable, Sendable { case none, working, waiting }

        package let text: String
        package let spoken: String
        package let cue: Cue

        /// `isAvailable` is false only while the channel's phase `isUnavailable`. Through a reconnect the
        /// last reported presence stays, so statuses don't blink.
        package init(presence: ChannelAgentPresence?, isAvailable: Bool) {
            guard isAvailable else {
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
    }
}
