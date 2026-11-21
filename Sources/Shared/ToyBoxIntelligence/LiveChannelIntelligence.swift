import Foundation
import FoundationModels
import Synchronization

/// The on-device service. Model work runs one generation at a time, catch-ups first, and results
/// are cached: catch-ups in memory by boundary, descriptions on disk by attachment.
public final class LiveChannelIntelligence: ChannelIntelligenceService {
    public static let shared = LiveChannelIntelligence()

    let model = SystemLanguageModel.default
    let queue = GenerationQueue()
    /// Shared by the transcript's card and Siri, so a channel summarized in one is instant in the other.
    /// A cached nil remembers a decline that asking again would repeat.
    let catchUps = Mutex(LRUCache<CatchUpRequest.Key, CatchUp?>(limit: 32))
    let altTexts: AltTextStore

    init(altTexts: AltTextStore = AltTextStore()) {
        self.altTexts = altTexts
    }

    public var availability: IntelligenceAvailability {
        IntelligenceAvailability(model.availability, supportsLocale: model.supportsLocale(.current))
    }

    public func catchUp(_ request: CatchUpRequest) async -> CatchUp? {
        await catchUpOutcome(request).result
    }

    public func altText(_ request: AltTextRequest) async -> String? {
        await altTextOutcome(request)?.text
    }

    /// The catch-up with its trace, for evaluation.
    func catchUpOutcome(_ request: CatchUpRequest) async -> CatchUpOutcome {
        guard availability.isAvailable else { return CatchUpOutcome(result: nil, cacheable: false) }
        if let cached = catchUps.withLock({ $0.value(for: request.key) }) {
            return CatchUpOutcome(result: cached, cacheable: true)
        }
        let generation = CatchUpGeneration(model: model)
        let outcome = await queue.run(key: "catch-up\n\(request.key)", priority: .catchUp) {
            let outcome = await generation.run(request)
            if outcome.cacheable { self.catchUps.withLock { $0.set(outcome.result, for: request.key) } }
            return outcome
        }
        return outcome ?? CatchUpOutcome(result: nil, cacheable: false)
    }

    /// The description with its details, for evaluation. Nil when unavailable or cancelled.
    func altTextOutcome(_ request: AltTextRequest) async -> AltTextOutcome? {
        guard availability.isAvailable, model.capabilities.contains(.vision) else { return nil }
        let key = [request.key, "v\(AltTextPrompt.version)", model.variant.displayName].joined(separator: "\n")
        if let entry = await altTexts.entry(for: key) {
            return AltTextOutcome(text: entry.text, cacheable: true)
        }
        let generation = AltTextGeneration(model: model)
        let store = altTexts
        let url = request.fileURL
        let priority: GenerationQueue.Priority = request.priority == .focused ? .focused : .visible
        return await queue.run(key: "alt-text\n\(key)", priority: priority) {
            let outcome = await generation.run(url)
            if outcome.cacheable, !Task.isCancelled {
                await store.store(AltTextStore.Entry(text: outcome.text), for: key)
            }
            return outcome
        }
    }
}
