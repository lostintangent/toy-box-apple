import ChannelKit
import Foundation
import Observation

/// Cross-surface intents within one channel window. Each surface owns its own presentation and
/// only uses this object to ask another surface to do something, such as Reply or Reveal.
@MainActor @Observable
final class ChannelInteraction {
    /// Transcript filter from the Message View menu. It never changes audience or read policy.
    var messageView: TranscriptView = .all
    var isInspectorPresented = true

    /// The composer consumes these. `token` changes on every request so repeats still fire.
    private(set) var replyRequest: (agent: ChannelAgent, token: UUID)?
    private(set) var composerFocusRequest = UUID()

    /// The transcript consumes this to scroll to, page toward and briefly highlight a message.
    private(set) var revealRequest: (sequence: Int, token: UUID)?
    private(set) var jumpToLatestRequest = UUID()

    func reply(to agent: ChannelAgent) {
        guard agent.deleted != true else { return }
        replyRequest = (agent, UUID())
    }

    func focusComposer() { composerFocusRequest = UUID() }
    func reveal(sequence: Int) { revealRequest = (sequence, UUID()) }
    func jumpToLatest() { jumpToLatestRequest = UUID() }
}
