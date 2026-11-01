import ChannelKit
import Foundation
import Testing
@testable import ChannelIntelligence

enum TestChannel {
    static let server = URL(string: "http://127.0.0.1:3210")!

    static func fixture(_ name: String) throws -> ChannelState {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(ChannelState.self, from: Data(contentsOf: url))
    }

    /// The studio demo's agents with the given messages.
    static func state(_ messages: [ChannelMessage], requestSequence: Int? = nil) throws -> ChannelState {
        var state = try fixture("studio-demo")
        state.messages = messages
        state.channel.requestSequence = requestSequence
        state.request = messages.last { $0.request == true }
        return state
    }

    static func message(_ sequence: Int, from sender: String = "studio-demo", _ text: String,
                        request: Bool? = nil, images: Int = 0) -> ChannelMessage {
        ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T10:00:00.000Z",
                       sender: sender == "user" ? .user : .agent(sender), content: .text(text), request: request,
                       attachments: images == 0 ? nil : (0..<images).map { ChannelAttachment(name: "image-\($0).png") })
    }

    static func event(_ sequence: Int, _ content: ChannelSystemContent) -> ChannelMessage {
        ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T10:00:00.000Z",
                       sender: .system, content: .system(content))
    }

    static let paragraph = """
        Messages and reconnects now share one public Channel state, so a reconnect replays exactly what \
        the reader missed and nothing else. I also moved read receipts behind the same reducer, which \
        keeps them monotonic across tabs. The old polling path is gone, and the transcript no longer \
        flickers when a snapshot arrives late.
        """
}

/// Answers catch-ups in turn, then keeps the last result (declining when there are none), and answers
/// alt text with `text`. `count` tallies every model call. A `holding` service suspends each call until
/// the test answers it, so tests can interleave cancellation, timeouts and late answers.
actor ScriptedIntelligence: ChannelIntelligenceService {
    nonisolated let availability: IntelligenceAvailability
    private var results: [CatchUpResult]
    private let text: String?
    private let holding: Bool
    private var catchUps: [CheckedContinuation<CatchUpResult, Never>?] = []
    private var altTexts: [CheckedContinuation<AltText?, Never>?] = []
    private var waiters: [(calls: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var count = 0

    init(availability: IntelligenceAvailability = .available, results: [CatchUpResult] = [], text: String? = nil,
         holding: Bool = false) {
        self.availability = availability
        self.results = results
        self.text = text
        self.holding = holding
    }

    func catchUp(_ request: CatchUpRequest) async -> CatchUpResult {
        count += 1
        guard holding else { return results.count > 1 ? results.removeFirst() : results.first ?? .declined }
        return await withCheckedContinuation { continuation in
            catchUps.append(continuation)
            resumeWaiters()
        }
    }

    func altText(_ request: AltTextRequest) async -> AltText? {
        count += 1
        guard holding else { return text.map(AltText.init) }
        return await withCheckedContinuation { continuation in
            altTexts.append(continuation)
            resumeWaiters()
        }
    }

    func waitForCalls(_ calls: Int) async {
        if count >= calls { return }
        await withCheckedContinuation { waiters.append((calls, $0)) }
    }

    func answer(_ index: Int, with result: CatchUpResult) {
        let continuation = catchUps[index]
        catchUps[index] = nil
        continuation?.resume(returning: result)
    }

    func answerAll(with result: CatchUpResult) {
        for index in catchUps.indices { answer(index, with: result) }
    }

    func answerAltText(_ result: String?) {
        for index in altTexts.indices {
            altTexts[index]?.resume(returning: result.map(AltText.init))
            altTexts[index] = nil
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { $0.calls <= count }
        waiters.removeAll { $0.calls <= count }
        for waiter in ready { waiter.continuation.resume() }
    }
}
