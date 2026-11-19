import ToyBoxClient
import ToyBoxKit
import QuickLook
import SwiftUI

/// A request preview's attachment: a 48-point square that an image fills, a video's poster with a
/// play badge, or a file's icon. An image opens through `openImage`, into each app's viewer. A
/// video presents each app's player and a file downloads into Quick Look, as their transcript
/// tiles do, or through `present` where the square can't present over itself.
public struct TranscriptAttachmentSquare<Player: View>: View {
    let attachment: ChannelAttachment
    let api: ChannelAPI
    /// Set for an attachment the app's viewer shows.
    let openImage: (() -> Void)?
    let fallback: ChannelThumbnails.Fallback?
    /// Set where the square sits in something that closes when covered, like a popover, so the
    /// window presents a video's resource or a file's downloaded copy in its place.
    let present: ((ChannelAttachment, URL) -> Void)?
    let player: () -> Player
    @ViewState private var thumbnail: CGImage?
    @ViewState private var failed = false
    @ViewState private var retry = 0
    @ViewState private var isLoading = false
    @ViewState private var isPlaying = false
    @ViewState private var preview: URL?
    @Environment(\.displayScale) private var displayScale

    public static var side: CGFloat { 48 }
    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 6, style: .continuous) }

    public init(attachment: ChannelAttachment, api: ChannelAPI, openImage: (() -> Void)?,
                fallback: ChannelThumbnails.Fallback? = nil, present: ((ChannelAttachment, URL) -> Void)? = nil,
                @ViewBuilder player: @escaping () -> Player) {
        self.attachment = attachment
        self.api = api
        self.openImage = openImage
        self.fallback = fallback
        self.present = present
        self.player = player
    }

    private var videoURL: URL? {
        guard attachment.isVideo, let address = attachment.url else { return nil }
        return api.resourceURL(address)
    }

    public var body: some View {
        Button(action: activate) {
            ZStack {
                Self.shape.fill(.quaternary)
                content
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(Self.shape)
            .transcriptAttachmentEdge(Self.shape)
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .help(failed ? "Couldn't open \(attachment.displayName). \(Self.tryAgain)" : attachment.displayName)
        .accessibilityLabel(openImage == nil ? attachment.displayName : "View \(attachment.displayName)")
        .accessibilityValue(failed ? "Couldn't load" : "")
        .accessibilityHint(failed ? "Tries again" : "")
        #if os(iOS)
        .fullScreenCover(isPresented: $isPlaying, content: player)
        #else
        .sheet(isPresented: $isPlaying, content: player)
        #endif
        .quickLookPreview($preview)
        .task(id: retry) { await loadThumbnail() }
    }

    @ViewBuilder private var content: some View {
        let shown = thumbnail ?? ChannelThumbnails.remembered(for: attachment, api: api)
        if let shown {
            Image(decorative: shown, scale: 1).resizable().scaledToFill()
                .frame(width: Self.side, height: Self.side)
        }
        if videoURL != nil {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.45))
        } else if isLoading || (openImage != nil && shown == nil && !failed) {
            DelayedProgressView().controlSize(.small)
        } else if failed && shown == nil {
            Image(systemName: openImage == nil ? "exclamationmark.triangle" : "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
        } else if shown == nil {
            Image(systemName: "doc").font(.title3).foregroundStyle(.secondary)
        }
    }

    private func activate() {
        if let openImage {
            if thumbnail == nil && failed { retry += 1 } else { openImage() }
        } else if let videoURL {
            if let present { present(attachment, videoURL) } else { isPlaying = true }
        } else {
            Task { await openFile() }
        }
    }

    private func loadThumbnail() async {
        if let videoURL {
            thumbnail = await TranscriptVideo<EmptyView>.loadPoster(for: attachment, url: videoURL, api: api)
            return
        }
        guard openImage != nil else { return }
        failed = false
        do {
            thumbnail = try await ChannelThumbnails.load(for: attachment, api: api, scale: displayScale,
                                                         reload: retry > 0, fallback: fallback).image
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }

    private func openFile() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let file = try await ChannelAttachmentCache.shared.file(for: attachment, api: api, reload: failed)
            failed = false
            if let present { present(attachment, file) } else { preview = file }
        } catch {
            failed = true
        }
    }

    #if os(iOS)
    private static var tryAgain: String { "Tap to try again." }
    #else
    private static var tryAgain: String { "Click to try again." }
    #endif
}
