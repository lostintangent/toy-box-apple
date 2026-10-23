import Foundation
import FoundationModels

/// The on-device service. Model work runs one generation at a time, catch-ups first, and results
/// are cached: catch-ups in memory by boundary, descriptions on disk by attachment.
public final class LiveChannelIntelligence: ChannelIntelligenceService {
    public static let shared = LiveChannelIntelligence()

    let model: SystemLanguageModel
    let queue: GenerationQueue
    let catchUps = CatchUpStore()
    let altTexts: AltTextStore

    init(model: SystemLanguageModel = .default, queue: GenerationQueue = GenerationQueue(),
         altTexts: AltTextStore = AltTextStore()) {
        self.model = model
        self.queue = queue
        self.altTexts = altTexts
    }

    public var availability: IntelligenceAvailability {
        IntelligenceAvailability(model.availability, supportsLocale: model.supportsLocale(.current))
    }

    public func catchUp(_ request: CatchUpRequest) async -> CatchUpResult {
        await catchUpOutcome(request).result
    }

    public func altText(_ request: AltTextRequest) async -> AltText? {
        await altTextOutcome(request)?.text
    }

    /// The catch-up with its trace, for evaluation.
    func catchUpOutcome(_ request: CatchUpRequest) async -> CatchUpOutcome {
        if case .unavailable(let reason) = availability {
            return CatchUpOutcome(result: .unavailable(reason), cacheable: false)
        }
        if let cached = await catchUps.result(for: request.key) {
            return CatchUpOutcome(result: cached, cacheable: true)
        }
        let generation = CatchUpGeneration(model: model)
        let store = catchUps
        let outcome = await queue.run(key: "catch-up\n\(request.key)", priority: .catchUp) {
            let outcome = await generation.run(request)
            if outcome.cacheable { await store.set(outcome.result, for: request.key) }
            return outcome
        }
        return outcome ?? CatchUpOutcome(result: .declined, cacheable: false)
    }

    /// The description with its details, for evaluation. Nil when unavailable or cancelled.
    func altTextOutcome(_ request: AltTextRequest) async -> AltTextOutcome? {
        guard availability.isAvailable, model.capabilities.contains(.vision) else { return nil }
        let key = [request.key, "v\(AltTextPrompt.version)", model.variant.displayName].joined(separator: "\n")
        if let entry = await altTexts.entry(for: key) {
            return AltTextOutcome(text: entry.text.map(AltText.init), cacheable: true)
        }
        let generation = AltTextGeneration(model: model)
        let store = altTexts
        let url = request.fileURL
        let priority: GenerationQueue.Priority = request.priority == .focused ? .focused : .visible
        return await queue.run(key: "alt-text\n\(key)", priority: priority) {
            let outcome = await generation.run(url)
            if outcome.cacheable, !Task.isCancelled {
                await store.store(AltTextStore.Entry(text: outcome.text?.text), for: key)
            }
            return outcome
        }
    }
}

actor CatchUpStore {
    private var results = LRUCache<CatchUpRequest.Key, CatchUpResult>(limit: 32)

    func result(for key: CatchUpRequest.Key) -> CatchUpResult? {
        results.value(for: key)
    }

    func set(_ result: CatchUpResult, for key: CatchUpRequest.Key) {
        results.set(result, for: key)
    }
}
