import ChannelClient
import ChannelKit
import Foundation
import Observation
import QuickLook
import ToyBoxUI

@MainActor @Observable
final class ArtifactReaderState {
    var preview: URL?
    var sharing: ArtifactShare?
    var isPreparingOriginal = false
    var imageRevision = 0
    @ObservationIgnored var markdownOffsets: [String: CGFloat] = [:]
    @ObservationIgnored var webReadingStates: [String: ArtifactWebReadingState] = [:]
    @ObservationIgnored weak var webRenderer: ArtifactWebRenderer?
    @ObservationIgnored weak var imageView: ArtifactImageScrollView?
    @ObservationIgnored private(set) var originalTask: Task<Void, Never>?
    @ObservationIgnored private var actionToken = UUID()
    @ObservationIgnored private var preparedOriginals: [OriginalIdentity: URL] = [:]
    @ObservationIgnored private let download: ArtifactContent.Download

    init(download: @escaping ArtifactContent.Download = ArtifactDownload.file) { self.download = download }

    deinit { originalTask?.cancel() }

    func prepareOriginal(session: ChannelArtifactSession, sharing: Bool) {
        guard !isPreparingOriginal, let artifact = session.artifact else { return }
        guard let resource = session.resource, let server = session.server, let channel = session.channelID,
              !session.isUnavailable else {
            session.actionError = "The original artifact is unavailable."
            return
        }
        let identity = OriginalIdentity(server: server, channel: channel, artifact: artifact.id)
        let file = session.content?.file ?? preparedOriginals[identity]
        let token = UUID()
        actionToken = token
        session.actionError = nil
        isPreparingOriginal = true
        originalTask = Task { [weak self, weak session, download] in
            defer {
                if let self, actionToken == token {
                    isPreparingOriginal = false
                    originalTask = nil
                }
            }
            do {
                let original: URL
                if let file { original = file }
                else { original = try await download(artifact, resource) }
                try Task.checkCancellation()
                guard let self, let session, actionToken == token,
                      session.server == server, session.channelID == channel,
                      session.artifact?.id == artifact.id, !session.isUnavailable else { return }
                preparedOriginals[identity] = original
                if sharing { self.sharing = ArtifactShare(file: original) }
                else if QLPreviewController.canPreview(original as NSURL) { preview = original }
                else {
                    session.actionError = "Quick Look cannot preview this file. Use Share Original to open it in another app."
                }
            } catch is CancellationError {
            } catch {
                guard let self, actionToken == token, let session,
                      session.server == server, session.channelID == channel,
                      session.artifact?.id == artifact.id else { return }
                session.actionError = error.localizedDescription
            }
        }
    }

    func stopPendingOriginal() {
        actionToken = UUID()
        originalTask?.cancel()
        originalTask = nil
        isPreparingOriginal = false
    }

    func cancelOriginal() {
        stopPendingOriginal()
        preview = nil
        sharing = nil
    }

    func reset() {
        cancelOriginal()
        markdownOffsets = [:]
        webRenderer?.stop()
        webRenderer = nil
        for state in webReadingStates.values { state.position.cancel() }
        webReadingStates = [:]
        preparedOriginals = [:]
        imageView?.stop()
        imageView = nil
    }

    func reload(_ session: ChannelArtifactSession) {
        if let id = session.artifact?.id, let state = webRenderer?.readingState { webReadingStates[id] = state }
        session.reload()
    }

    private struct OriginalIdentity: Hashable {
        let server: URL
        let channel: String
        let artifact: String
    }
}
