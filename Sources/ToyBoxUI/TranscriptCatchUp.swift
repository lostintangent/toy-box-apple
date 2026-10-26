import ChannelIntelligence
import ChannelKit
import Foundation
import Observation
import SwiftUI

/// The catch-up summary for one landing in a channel: what the card shows, the generation the
/// transcript runs for it, and how its height changes move the rows around it.
@MainActor @Observable
public final class TranscriptCatchUp {
    public struct Boundary: Hashable {
        public let server: String
        public let channelId: String
        public let unreadAfter: Int
    }

    /// A summary with the count its header reads, which an update replaces together.
    public struct Summary: Hashable {
        public let catchUp: CatchUp
        public let count: Int
    }

    /// A summary never animates the card's height, because each frame of that lays out the whole
    /// transcript. The card takes its new height in one pass and only its lines fade, so Reduce
    /// Motion needs no variant.
    public enum Phase: Equatable {
        case loading
        case ready(Summary)
        /// Update is regenerating. The summary it replaces stays, dimmed, until the new one arrives.
        case updating(Summary)
        case collapsed
    }

    public let boundary: Boundary
    public private(set) var request: CatchUpRequest
    public private(set) var phase: Phase
    /// Fading out, before the card collapses.
    public private(set) var isFading = false
    /// A new value whenever a generation is due. The transcript runs it in a task it owns, so a card
    /// that scrolls out of the lazy stack never cancels it.
    public private(set) var generation: UUID?
    /// Until the reader scrolls, uses the keyboard or reveals anything, the transcript doesn't follow
    /// its bottom, so the card's top stays where it landed.
    public var isPinned = true
    /// The top of the card and New divider in the viewport, measured by the divider row. The
    /// transcript keeps the rows below in place when the card changes height above the viewport.
    @ObservationIgnored public var top: CGFloat?
    @ObservationIgnored private let timeout: Duration
    /// What the summary being updated was made from, restored if the update fails so Update can retry.
    @ObservationIgnored private var updatingFrom: CatchUpRequest?

    private static var dismissed: Set<Boundary> = []
    private static var results: [CatchUpRequest.Key: Summary] = [:]
    private static var resultOrder: [CatchUpRequest.Key] = []

    /// Nil unless the landing is eligible: the model is available, the setting is on, All Messages is
    /// showing, this boundary's summary wasn't dismissed, and enough unread text came from others.
    public static func make(server: URL, state: ChannelState, unreadAfter: Int?, view: TranscriptView,
                     availability: IntelligenceAvailability, isOn: Bool,
                     timeout: Duration = .seconds(15)) -> TranscriptCatchUp? {
        guard availability.isAvailable, isOn, view == .all,
              let request = CatchUpRequest(server: server, state: state, unreadAfter: unreadAfter) else { return nil }
        let catchUp = TranscriptCatchUp(request: request, timeout: timeout)
        return dismissed.contains(catchUp.boundary) ? nil : catchUp
    }

    public init(request: CatchUpRequest, timeout: Duration = .seconds(15)) {
        boundary = Boundary(server: request.key.server, channelId: request.key.channelId,
                            unreadAfter: request.key.unreadAfter)
        self.request = request
        self.timeout = timeout
        // A summary made earlier this session is there on the first frame.
        if let summary = Self.results[request.key] {
            phase = .ready(summary)
        } else {
            phase = .loading
            generation = UUID()
        }
    }

    public var summary: Summary? {
        switch phase {
        case .ready(let summary), .updating(let summary): summary
        case .loading, .collapsed: nil
        }
    }

    public var isGenerating: Bool {
        switch phase {
        case .loading, .updating: true
        case .ready, .collapsed: false
        }
    }

    public var title: String {
        if isGenerating { return "Summarizing \(request.unreadFromOthers) new messages" }
        return "Summary of \(summary?.count ?? request.unreadFromOthers) new messages"
    }

    /// Whether following the transcript's bottom must wait, so the card's top holds still.
    public var holdsLanding: Bool { isPinned && phase != .collapsed }

    public func run(using service: any ChannelIntelligenceService) async {
        guard generation != nil, isGenerating else { return }
        let request = request
        let timeout = timeout
        let result = await withTaskGroup(of: CatchUpResult?.self) { group in
            group.addTask { await service.catchUp(request) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard !Task.isCancelled, request == self.request else { return }
        if let catchUp = result?.catchUp {
            let summary = Summary(catchUp: catchUp, count: request.unreadFromOthers)
            Self.remember(summary, for: request.key)
            phase = .ready(summary)
        } else if case .updating(let previous) = phase {
            // A failed update keeps the summary the reader already has, along with its Update.
            if let updatingFrom { self.request = updatingFrom }
            withAnimation(.easeOut(duration: 0.2)) { phase = .ready(previous) }
        } else {
            await collapse()
        }
    }

    /// Regenerates through the newest message, keeping this landing's boundary.
    public func update(from state: ChannelState, server: URL) {
        guard case .ready(let current) = phase,
              let request = CatchUpRequest(server: server, state: state, unreadAfter: boundary.unreadAfter),
              request.key != self.request.key else { return }
        updatingFrom = self.request
        self.request = request
        if let summary = Self.results[request.key] {
            phase = .ready(summary)
            return
        }
        withAnimation(.easeOut(duration: 0.2)) { phase = .updating(current) }
        generation = UUID()
    }

    /// The summary stays gone for this channel and boundary for the rest of the session.
    public func dismiss() {
        Self.dismissed.insert(boundary)
        generation = nil
        Task { await collapse() }
    }

    /// Fades the card, then removes it in one layout pass.
    private func collapse() async {
        guard phase != .collapsed, !isFading else { return }
        withAnimation(.easeOut(duration: 0.15)) { isFading = true }
        try? await Task.sleep(for: .milliseconds(150))
        phase = .collapsed
    }

    private static func remember(_ summary: Summary, for key: CatchUpRequest.Key) {
        if results.updateValue(summary, forKey: key) == nil { resultOrder.append(key) }
        while resultOrder.count > 32 { results.removeValue(forKey: resultOrder.removeFirst()) }
    }
}


/// What leads a summary line: the pending request's state, or its first source's sender, which
/// for a channel event is that event's own symbol as the transcript draws it.
public enum TranscriptCatchUpSlot: Equatable {
    case need(isReplied: Bool)
    case avatar(String)
    case event(String?)
    case unknown

    /// `isReplied` is nil unless the line is the Needs You line.
    public init(line: CatchUp.Line, messages: [ChannelMessage], isReplied: Bool?) {
        if let isReplied { self = .need(isReplied: isReplied); return }
        let source = messages.first { $0.sequence == line.sources.first }
        if let agentId = source?.sender.agentId { self = .avatar(agentId) }
        else if let event = source?.system { self = .event(event.type) }
        else { self = .unknown }
    }
}
