import Foundation
import FoundationModels

/// How a generation ended, beyond its result: whether it may be cached, and what happened on the
/// way, for evaluation.
struct CatchUpOutcome: Sendable {
    var result: CatchUpResult
    var cacheable: Bool
    var trace = CatchUpTrace()
}

struct CatchUpTrace: Sendable {
    var budget = 0
    var promptTokens: Int?
    var candidateLines = 0
    var shownLines = 0
    var draft: CatchUpDraft?
    var rejected: [CatchUpRejection] = []
    var error: String?
    var attempts = 0
    var duration: Duration = .zero
}

/// The ways a generation can fail, mapped from Foundation Models errors.
enum GenerationFailure: Equatable, Sendable {
    case cancelled
    case tooLong
    /// The model declined the content. Asking again gives the same answer.
    case refused
    case unavailable(IntelligenceUnavailableReason)
    /// Rate limits, timeouts and anything unexpected. Worth trying again later.
    case transient

    init(_ error: any Error) {
        switch error {
        case is CancellationError:
            self = .cancelled
        case let error as LanguageModelError:
            switch error {
            case .contextSizeExceeded: self = .tooLong
            case .guardrailViolation, .refusal: self = .refused
            case .unsupportedLanguageOrLocale: self = .unavailable(.unsupportedLanguage)
            default: self = .transient
            }
        case is SystemLanguageModel.Error:
            self = .unavailable(.modelNotReady)
        default:
            self = Task.isCancelled ? .cancelled : .transient
        }
    }
}

extension IntelligenceAvailability {
    init(_ availability: SystemLanguageModel.Availability, supportsLocale: Bool) {
        switch availability {
        case .available:
            self = supportsLocale ? .available : .unavailable(.unsupportedLanguage)
        case .unavailable(.deviceNotEligible):
            self = .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            self = .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable:
            self = .unavailable(.modelNotReady)
        @unknown default:
            self = .unavailable(.modelNotReady)
        }
    }
}

struct CatchUpGeneration: Sendable {
    static let safetyMargin = 96

    let model: SystemLanguageModel

    func run(_ request: CatchUpRequest) async -> CatchUpOutcome {
        let start = ContinuousClock.now
        var outcome = await generate(request)
        outcome.trace.duration = ContinuousClock.now - start
        return outcome
    }

    /// Tokens left for the prompt once instructions, schema and the answer are accounted for.
    func budget(needsYou: Bool) async -> Int {
        let instructions = (try? await model.tokenCount(for: Instructions(CatchUpPrompt.instructions)))
            ?? CatchUpPrompt.estimatedTokens(CatchUpPrompt.instructions)
        let schema = (try? await model.tokenCount(for: CatchUpSchema.schema(needsYou: needsYou))) ?? 300
        return model.contextSize - instructions - schema - CatchUpPrompt.maximumResponseTokens - Self.safetyMargin
    }

    private func generate(_ request: CatchUpRequest) async -> CatchUpOutcome {
        var trace = CatchUpTrace()
        trace.candidateLines = request.entries.count
        let needsYou = request.request != nil
        trace.budget = await budget(needsYou: needsYou)
        let fitted = await CatchUpPrompt.fitted(request, budget: trace.budget) { text in
            (try? await model.tokenCount(for: Prompt(text))) ?? CatchUpPrompt.estimatedTokens(text)
        }
        guard var prompt = fitted else {
            trace.error = "Prompt doesn't fit"
            return CatchUpOutcome(result: .declined, cacheable: true, trace: trace)
        }

        while true {
            if Task.isCancelled { return CatchUpOutcome(result: .declined, cacheable: false, trace: trace) }
            trace.attempts += 1
            trace.shownLines = prompt.entries.count
            trace.promptTokens = try? await model.tokenCount(for: Prompt(prompt.text))
            do {
                let session = LanguageModelSession(model: model, instructions: Instructions(CatchUpPrompt.instructions))
                let response = try await session.respond(
                    to: Prompt(prompt.text), schema: CatchUpSchema.schema(needsYou: needsYou),
                    options: GenerationOptions(samplingMode: .greedy,
                                               maximumResponseTokens: CatchUpPrompt.maximumResponseTokens))
                let draft = try CatchUpSchema.draft(response.content)
                let assembly = draft.assembled(prompt: prompt, request: request)
                trace.draft = draft
                trace.rejected = assembly.rejected
                return CatchUpOutcome(result: assembly.result, cacheable: true, trace: trace)
            } catch {
                trace.error = String(describing: error)
                switch GenerationFailure(error) {
                case .tooLong:
                    guard trace.attempts == 1, let half = prompt.halved() else {
                        return CatchUpOutcome(result: .declined, cacheable: true, trace: trace)
                    }
                    prompt = half
                case .refused:
                    return CatchUpOutcome(result: .declined, cacheable: true, trace: trace)
                case .unavailable(let reason):
                    return CatchUpOutcome(result: .unavailable(reason), cacheable: false, trace: trace)
                case .cancelled, .transient:
                    return CatchUpOutcome(result: .declined, cacheable: false, trace: trace)
                }
            }
        }
    }
}

/// The catch-up response schema. The needs-you sentence is requested only while a request waits,
/// so the model is never asked to imagine one.
enum CatchUpSchema {
    private static let withoutRequest = Result { try makeSchema(needsYou: false) }
    private static let withRequest = Result { try makeSchema(needsYou: true) }

    static func schema(needsYou: Bool) throws -> GenerationSchema {
        try (needsYou ? withRequest : withoutRequest).get()
    }

    private static func makeSchema(needsYou: Bool) throws -> GenerationSchema {
        // Schema names and property order are model input, independent of the Swift draft types.
        let change = DynamicGenerationSchema(name: "CatchUpChangeContent", description: "One meaningful change", properties: [
            .init(name: "sources", description: "Numbers of the unread messages this change comes from",
                  schema: .init(type: [Int].self, guides: [.minimumCount(1), .maximumCount(4)])),
            .init(name: "summary", description: """
                One past-tense sentence of at most 16 words naming who did what. Only facts from the \
                cited messages.
                """, schema: .init(type: String.self)),
        ])
        var properties = [
            DynamicGenerationSchema.Property(name: "changes", description: """
                At most three meaningful changes from the unread messages, most important first. Empty when \
                nothing meaningful happened.
                """, schema: .init(arrayOf: change, maximumElements: 3)),
        ]
        if needsYou {
            properties.insert(.init(name: "needsYou", description: """
                One sentence of at most 20 words that opens with the waiting message's speaker and says \
                exactly what they asked you to do, answer or decide. The ask often comes last, after an \
                update. Don't add how to reply. Use only the waiting message.
                """, schema: .init(type: String.self)), at: 0)
        }
        return try GenerationSchema(root: .init(
            name: needsYou ? "CatchUpWithRequestContent" : "CatchUpContent",
            description: "What changed since the reader's last visit", properties: properties), dependencies: [])
    }

    static func draft(_ content: GeneratedContent) throws -> CatchUpDraft {
        CatchUpDraft(needsYou: try? content.value(String.self, forProperty: "needsYou"),
                     changes: try content.value([CatchUpDraft.Change].self, forProperty: "changes"))
    }
}

extension CatchUpDraft.Change: ConvertibleFromGeneratedContent {
    init(_ content: GeneratedContent) throws {
        sources = try content.value([Int].self, forProperty: "sources")
        summary = try content.value(String.self, forProperty: "summary")
    }
}
