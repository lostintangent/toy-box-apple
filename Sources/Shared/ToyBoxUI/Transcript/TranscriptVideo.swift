import AVFoundation
import ChannelClient
import ChannelKit
import SwiftUI
import WebKit

extension ChannelAttachment {
    /// Whether the system's player decodes this video. WebKit plays the rest, like WebM, as the web does.
    public var playsInSystemPlayer: Bool {
        contentType.map { AVURLAsset.audiovisualTypes().contains(AVFileType($0.identifier)) } ?? false
    }
}

/// A video's tile: a poster, when the system's player can decode it, and an explicit Play that
/// presents each app's own player. A missing poster still plays.
public struct TranscriptVideo<Player: View>: View {
    let attachment: ChannelAttachment
    let url: URL
    let api: ChannelAPI
    let player: () -> Player
    @ViewState private var poster: CGImage?
    @ViewState private var isPlaying = false

    public init(attachment: ChannelAttachment, url: URL, api: ChannelAPI, @ViewBuilder player: @escaping () -> Player) {
        self.attachment = attachment
        self.url = url
        self.api = api
        self.player = player
    }

    public var body: some View {
        Button { isPlaying = true } label: {
            VStack(spacing: 8) {
                if let poster = poster ?? ChannelThumbnails.remembered(for: attachment, api: api) {
                    Image(decorative: poster, scale: 1).resizable().scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 120)
                        .clipShape(.transcriptAttachment)
                        .transcriptAttachmentEdge(.transcriptAttachment)
                }
                Label("Play \(attachment.displayName)", systemImage: "play.circle.fill")
                    .font(.transcriptAttachment)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: 240, minHeight: 44)
            .background(.quaternary, in: .transcriptAttachment)
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .fullScreenCover(isPresented: $isPlaying, content: player)
        #else
        .sheet(isPresented: $isPlaying, content: player)
        #endif
        .task(id: url) {
            guard attachment.playsInSystemPlayer, ChannelThumbnails.remembered(for: attachment, api: api) == nil
            else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 320)
            guard let image = try? await generator.image(at: .zero).image else { return }
            poster = ChannelThumbnails.remember(image, for: attachment, api: api)
        }
    }
}

/// WebKit's player, for a video the system's player can't decode. It streams from the server,
/// since a page can't read a local file.
public struct TranscriptWebVideo: View {
    let url: URL
    @ViewState private var page = WebPage()

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        WebView(page)
            .task(id: url) { _ = page.load(html: Self.page(playing: url), baseURL: url) }
    }

    /// A page of its own, because WebKit's video page holds a 700-point minimum width on the Mac.
    static func page(playing url: URL) -> String {
        let source = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
            <!doctype html><meta name="viewport" content="width=device-width">
            <style>html, body { margin: 0; height: 100%; background: #000 }
            video { display: block; width: 100%; height: 100% }</style>
            <video src="\(source)" controls autoplay playsinline></video>
            """
    }
}
