import ChannelKit
import Foundation
import Observation

/// One landing's on-device summary. Hosts own its geometry and animate only its contents.
@MainActor @Observable
public final class TranscriptCatchUpSession {
    public struct Boundary: Sendable, Hashable {
        public let server: String
        public let channelId: String
        public let unreadAfter: Int
    }

    public struct Summary: Sendable, Hashable {
        public let catchUp: CatchUp
        public let count: Int

        public init(catchUp: CatchUp, count: Int) {
            self.catchUp = catchUp
            self.count = count
        }

        /// The agent messages after this summary once there are enough to earn an Update, else nil.
        public func newerMessageCount(in messages: [ChannelMessage]) -> Int? {
            let count = channelAgentMessageCount(messages, after: catchUp.through)
            return count >= 4 ? count : nil
        }
    }

    public enum Phase: Sendable, Equatable {
        case loading
        case ready(Summary)
        case updating(Summary)
        case collapsed
    }

    public let boundary: Boundary
    public private(set) var request: CatchUpRequest
    public private(set) var phase: Phase
    public private(set) var isFading = false
    /// Hosts run generation outside their lazy card's lifetime.
    public private(set) var generation: UUID?

    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var updatingFrom: CatchUpRequest?
    @ObservationIgnored private var work: Work?
    @ObservationIgnored private var activeAttempt: UUID?

    private enum Outcome: Sendable {
        case result(CatchUpResult), timedOut, cancelled
    }

    private struct Work {
        let attempt: UUID
        let continuation: CheckedContinuation<Outcome, Never>
        let model: Task<Void, Never>
        let timer: Task<Void, Never>
    }

    private static var dismissed: Set<Boundary> = []
    private static var results: [CatchUpRequest.Key: Summary] = [:]
    private static var resultOrder: [CatchUpRequest.Key] = []

    /// A missing loaded boundary never triggers history loading just to make a summary.
    public static func make(server: URL, state: ChannelState, unreadAfter: Int?, view: TranscriptView,
                            boundaryIsLoaded: Bool, availability: IntelligenceAvailability, isOn: Bool,
                            timeout: Duration = .seconds(15)) -> TranscriptCatchUpSession? {
        guard boundaryIsLoaded, availability.isAvailable, isOn, view == .all,
              let request = CatchUpRequest(server: server, state: state, unreadAfter: unreadAfter) else { return nil }
        let boundary = Boundary(server: request.key.server, channelId: request.key.channelId,
                                unreadAfter: request.key.unreadAfter)
        guard !dismissed.contains(boundary) else { return nil }
        return TranscriptCatchUpSession(request: request, timeout: timeout)
    }

    public init(request: CatchUpRequest, timeout: Duration = .seconds(15)) {
        boundary = Boundary(server: request.key.server, channelId: request.key.channelId,
                            unreadAfter: request.key.unreadAfter)
        self.request = request
        self.timeout = timeout
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

    public func run(using service: any ChannelIntelligenceService) async {
        guard !Task.isCancelled, let generation, isGenerating, !isFading,
              !Self.dismissed.contains(boundary), activeAttempt == nil else { return }
        let attempt = UUID()
        activeAttempt = attempt
        defer { if activeAttempt == attempt { activeAttempt = nil } }
        let request = request
        let timeout = timeout
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let model = Task { [weak self] in
                    let result = await service.catchUp(request)
                    self?.finish(attempt, with: .result(result))
                }
                let timer = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.finish(attempt, with: .timedOut)
                }
                work = Work(attempt: attempt, continuation: continuation, model: model, timer: timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(attempt, with: .cancelled) }
        }
        guard !Task.isCancelled, generation == self.generation, request == self.request,
              !isFading, !Self.dismissed.contains(boundary) else { return }
        if case .cancelled = outcome { return }
        if case .result(.ready(let catchUp)) = outcome {
            let summary = Summary(catchUp: catchUp, count: request.unreadFromOthers)
            Self.remember(summary, for: request.key)
            phase = .ready(summary)
        } else if case .updating(let previous) = phase {
            if let updatingFrom { self.request = updatingFrom }
            updatingFrom = nil
            phase = .ready(previous)
        } else {
            await collapse()
        }
    }

    /// Explicitly replaces coverage, never in response to arrivals alone.
    public func update(from state: ChannelState, server: URL) {
        guard case .ready(let current) = phase, !isFading, !Self.dismissed.contains(boundary),
              intelligenceServerKey(server) == boundary.server, state.channel.id == boundary.channelId,
              current.newerMessageCount(in: state.messages) != nil,
              let request = CatchUpRequest(server: server, state: state, unreadAfter: boundary.unreadAfter),
              request.key.through > self.request.key.through else { return }
        updatingFrom = self.request
        self.request = request
        if let summary = Self.results[request.key] {
            updatingFrom = nil
            phase = .ready(summary)
            return
        }
        phase = .updating(current)
        generation = UUID()
    }

    public func dismiss() {
        Self.dismissed.insert(boundary)
        if let work { finish(work.attempt, with: .cancelled) }
        generation = nil
        Task { await collapse() }
    }

    private func finish(_ attempt: UUID, with outcome: Outcome) {
        guard let work, work.attempt == attempt else { return }
        self.work = nil
        work.model.cancel()
        work.timer.cancel()
        work.continuation.resume(returning: outcome)
    }

    private func collapse() async {
        guard phase != .collapsed, !isFading else { return }
        isFading = true
        try? await Task.sleep(for: .milliseconds(150))
        phase = .collapsed
    }

    private static func remember(_ summary: Summary, for key: CatchUpRequest.Key) {
        if results.updateValue(summary, forKey: key) == nil { resultOrder.append(key) }
        while resultOrder.count > 32 { results.removeValue(forKey: resultOrder.removeFirst()) }
    }
}

/// The semantic identity leading a grounded line. Native hosts choose its symbol, color and size.
public enum TranscriptCatchUpSlot: Sendable, Equatable {
    case need(isReplied: Bool)
    case avatar(String)
    case event(String?)
    case unknown

    public init(line: CatchUp.Line, messages: [ChannelMessage], isReplied: Bool?) {
        if let isReplied { self = .need(isReplied: isReplied); return }
        let source = messages.first { $0.sequence == line.sources.first }
        if let agentId = source?.sender.agentId { self = .avatar(agentId) }
        else if let event = source?.system { self = .event(event.type) }
        else { self = .unknown }
    }
}
