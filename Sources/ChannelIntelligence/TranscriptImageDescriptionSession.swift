import Foundation
import Observation

/// Generated descriptions shared by image tiles and the viewer. Hosts expose them only to VoiceOver.
@MainActor @Observable
public final class TranscriptImageDescriptionSession {
    public static let shared = TranscriptImageDescriptionSession()

    private var texts: [String: String] = [:]
    @ObservationIgnored private var finished: Set<String> = []

    public init() {}

    public static func isActive(voiceOver: Bool, isOn: Bool, using service: any ChannelIntelligenceService) -> Bool {
        voiceOver && isOn && service.availability.isAvailable
    }

    public func text(for request: AltTextRequest?) -> String? {
        request.flatMap { texts[$0.key] }
    }

    public func describe(_ request: AltTextRequest, using service: any ChannelIntelligenceService) async {
        guard !Task.isCancelled, !finished.contains(request.key) else { return }
        let text = await service.altText(request)?.text
        // A tile that scrolled away gives up its place in the queue and asks again when it returns.
        guard !Task.isCancelled else { return }
        finished.insert(request.key)
        if let text { texts[request.key] = text }
    }

    /// The accessibility value for a loaded image, empty until its description is ready.
    public static func value(_ text: String?) -> String {
        text.map { "Generated description: \($0)" } ?? ""
    }
}
