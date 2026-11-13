import AVFoundation
import ChannelKit
import SwiftUI
import WebKit

extension ChannelAttachment {
    /// Whether the system's player decodes this video. WebKit plays the rest, like WebM, as the web does.
    public var playsInSystemPlayer: Bool {
        contentType.map { AVURLAsset.audiovisualTypes().contains(AVFileType($0.identifier)) } ?? false
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
