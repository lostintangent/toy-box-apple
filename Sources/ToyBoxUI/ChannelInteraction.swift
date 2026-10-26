import ChannelKit
import Foundation
import Observation

/// Cross-surface intents within one channel window. Each surface owns its own presentation and
/// only uses this object to ask another surface to do something, such as Reply or Reveal.
@MainActor @Observable
public final class ChannelInteraction {
    /// Transcript filter from the Message View menu. It never changes audience or read policy.
    public var messageView: TranscriptView = .all
    public var isInspectorPresented: Bool
    public var isArtifactViewerPresented = false

    /// The composer consumes these. `token` changes on every request so repeats still fire.
    public private(set) var replyRequest: (agent: ChannelAgent, sequence: Int?, token: UUID)?
    public private(set) var composerFocusRequest = UUID()
    public var hasDraft = false
    public var copyDraft: (() -> Void)?
    public private(set) var editSendAttemptRequest: (id: String, token: UUID)?

    /// The transcript consumes this to scroll to, page toward and briefly highlight a message.
    public private(set) var revealRequest: (sequence: Int, token: UUID)?
    /// Consuming the request must not cancel the task handling it.
    public private(set) var revealRequestToken = UUID()
    public private(set) var jumpToLatestRequest = UUID()
    public private(set) var findRequest = UUID()
    public private(set) var findNavigation: (direction: Int, token: UUID)?

    public init(isInspectorPresented: Bool = true) {
        self.isInspectorPresented = isInspectorPresented
    }

    public func reply(to agent: ChannelAgent, sequence: Int? = nil) {
        guard agent.deleted != true else { return }
        replyRequest = (agent, sequence, UUID())
    }

    public func focusComposer() { composerFocusRequest = UUID() }
    public func editSendAttempt(id: String) { editSendAttemptRequest = (id, UUID()) }
    public func reveal(sequence: Int) {
        revealRequestToken = UUID()
        revealRequest = (sequence, revealRequestToken)
    }

    public func consumeRevealRequest(_ token: UUID) {
        if revealRequest?.token == token { revealRequest = nil }
    }
    public func jumpToLatest() { jumpToLatestRequest = UUID() }
    public func findInChannel() { findRequest = UUID() }
    public func findNext(_ direction: Int) { findNavigation = (direction, UUID()) }
}
