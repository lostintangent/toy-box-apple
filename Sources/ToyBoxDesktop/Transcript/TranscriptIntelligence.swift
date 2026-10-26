import Foundation
import ChannelClient
import ChannelIntelligence
import ChannelKit

typealias TranscriptImageDescriptions = TranscriptImageDescriptionSession

extension TranscriptImageDescriptionSession {
    /// Images are identified by their attachment cache digest, so a description outlives the file.
    static func request(for attachment: ChannelAttachment, api: ChannelAPI, file: URL?,
                        priority: AltTextRequest.Priority) -> AltTextRequest? {
        guard let file, let digest = ChannelAttachmentCache.destination(for: attachment, api: api)?
            .deletingPathExtension().lastPathComponent else { return nil }
        return AltTextRequest(server: api.baseURL, digest: digest, fileURL: file, priority: priority)
    }
}
