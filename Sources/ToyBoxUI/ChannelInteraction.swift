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
    public private(set) var overviewTasksRequest: UUID?
    private var requestPreviewCoverage: UUID?
    public var isRequestPreviewPresented: Bool { requestPreviewCoverage != nil }

    /// The composer consumes these. `token` changes on every request so repeats still fire.
    public private(set) var replyRequest: (agent: ChannelAgent, sequence: Int?, token: UUID)?
    public private(set) var composerFocusRequest = UUID()
    public private(set) var pendingComposerFocusRequest: UUID?
    public var hasDraft = false
    public var copyDraft: (() -> Void)?
    public private(set) var editSendAttemptRequest: (id: String, token: UUID)?

    /// The transcript consumes this to scroll to, page toward and briefly highlight a message.
    public private(set) var revealRequest: (sequence: Int, token: UUID)?
    /// How the latest reveal went. A caller compares the token `reveal(sequence:)` returned, so it
    /// never mistakes another reveal or an unrelated paging error for its own.
    public private(set) var revealProgress: RevealProgress?
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

    public func focusComposer() {
        composerFocusRequest = UUID()
        pendingComposerFocusRequest = composerFocusRequest
    }
    public func consumeComposerFocusRequest(_ token: UUID) {
        if pendingComposerFocusRequest == token { pendingComposerFocusRequest = nil }
    }
    public func editSendAttempt(id: String) { editSendAttemptRequest = (id, UUID()) }
    @discardableResult
    public func reveal(sequence: Int) -> UUID {
        revealRequestToken = UUID()
        revealRequest = (sequence, revealRequestToken)
        revealProgress = RevealProgress(token: revealRequestToken, sequence: sequence, outcome: .loading)
        return revealRequestToken
    }

    /// The transcript reports its reveal here. A later reveal replaces the progress, so a stale
    /// completion is ignored.
    public func finishReveal(_ token: UUID, _ outcome: RevealProgress.Outcome) {
        guard revealProgress?.token == token else { return }
        revealProgress?.outcome = outcome
    }

    public func consumeRevealRequest(_ token: UUID) {
        if revealRequest?.token == token { revealRequest = nil }
    }
    public func requestPreviewDidAppear(_ token: UUID) { requestPreviewCoverage = token }
    public func requestPreviewDidDisappear(_ token: UUID) {
        if requestPreviewCoverage == token { requestPreviewCoverage = nil }
    }
    public func jumpToLatest() { jumpToLatestRequest = UUID() }
    public func findInChannel() { findRequest = UUID() }
    public func findNext(_ direction: Int) { findNavigation = (direction, UUID()) }
    public func showOverviewTasks() {
        overviewTasksRequest = UUID()
        isInspectorPresented = true
    }
    public func consumeOverviewTasksRequest(_ token: UUID) {
        if overviewTasksRequest == token { overviewTasksRequest = nil }
    }
}

public struct RevealProgress: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case loading
        /// The message is in place and highlighted, not merely loaded.
        case revealed
        case failed(String)
    }

    public let token: UUID
    public let sequence: Int
    public var outcome: Outcome

    public init(token: UUID, sequence: Int, outcome: Outcome) {
        self.token = token
        self.sequence = sequence
        self.outcome = outcome
    }
}
