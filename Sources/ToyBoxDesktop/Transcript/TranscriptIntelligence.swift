import Foundation
import ChannelClient
import ChannelIntelligence
import ChannelKit
import Observation

/// The Intelligence toggles in Settings. Neither key registers a default, so an unset key reads as on.
enum TranscriptIntelligenceSettings {
    static let summarizesNewMessages = "summarizeNewMessages"
    static let describesImages = "describeImagesForVoiceOver"

    static func isOn(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// Generated image descriptions for VoiceOver, shared by inline tiles and the viewer so an image is
/// described once per session. They only ever appear as an accessibility value.
@MainActor @Observable
final class TranscriptImageDescriptions {
    static let shared = TranscriptImageDescriptions()

    private var texts: [String: String] = [:]
    @ObservationIgnored private var finished: Set<String> = []

    /// Descriptions are made only while VoiceOver is running, the setting is on and the model can run.
    static func isActive(voiceOver: Bool, isOn: Bool, using service: any ChannelIntelligenceService) -> Bool {
        voiceOver && isOn && service.availability.isAvailable
    }

    func text(for request: AltTextRequest?) -> String? {
        request.flatMap { texts[Self.key($0)] }
    }

    func describe(_ request: AltTextRequest, using service: any ChannelIntelligenceService) async {
        let key = Self.key(request)
        guard !finished.contains(key) else { return }
        let text = await service.altText(request)?.text
        // A tile that scrolled away gives up its place in the queue, and asks again when it returns.
        guard !Task.isCancelled else { return }
        finished.insert(key)
        if let text { texts[key] = text }
    }

    /// Images are identified by their attachment cache digest, so a description outlives the file.
    static func request(for attachment: ChannelAttachment, api: ChannelAPI, file: URL?,
                        priority: AltTextRequest.Priority) -> AltTextRequest? {
        guard let file, let digest = TranscriptAttachmentCache.destination(for: attachment, api: api)?
            .deletingPathExtension().lastPathComponent else { return nil }
        return AltTextRequest(server: api.baseURL, digest: digest, fileURL: file, priority: priority)
    }

    /// The accessibility value for a loaded image: empty until there is a description.
    static func value(_ text: String?) -> String {
        text.map { "Generated description: \($0)" } ?? ""
    }

    private static func key(_ request: AltTextRequest) -> String {
        request.server + "\n" + request.digest
    }
}
