import AVKit
import ChannelClient
import ChannelKit
import SwiftUI

struct TranscriptAttachments: View {
    let attachments: [ChannelAttachment]
    let api: ChannelAPI
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                if attachment.contentType?.conforms(to: .image) == true {
                    TranscriptImage(attachment: attachment, api: api)
                } else if attachment.contentType?.conforms(to: .movie) == true,
                          let address = attachment.url, let url = api.resourceURL(address) {
                    TranscriptVideo(url: url, name: attachment.displayName)
                } else {
                    TranscriptFileRow(attachment: attachment, api: api)
                }
            }
        }
    }
}

/// An image that reserves its box from the header before it decodes, so arriving pixels never
/// resize it. Decoded thumbnails stay cached, so a row scrolling back draws at once.
private struct TranscriptImage: View {
    let attachment: ChannelAttachment
    let api: ChannelAPI
    @ViewState private var image: UIImage?
    @ViewState private var failed = false
    @ViewState private var showsProgress = false
    @ViewState private var attempt = 0

    static let maximum = CGSize(width: 240, height: 160)
    static let unknown = CGSize(width: 120, height: 90)

    var body: some View {
        let shown = image ?? TranscriptThumbnails.remembered(for: attachment, api: api)
        let size = Self.fitted(ChannelImageDecoder.pixelSize(for: attachment, api: api) ?? shown?.size ?? .zero)
        ZStack {
            if let shown {
                Image(uiImage: shown).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
                if failed {
                    Button("Retry", systemImage: "arrow.clockwise") { failed = false; attempt += 1 }
                        .font(.footnote)
                } else if showsProgress {
                    ProgressView()
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .accessibilityLabel(attachment.displayName)
        .task(id: attempt) { await load() }
    }

    private func load() async {
        guard image == nil else { return }
        if let remembered = TranscriptThumbnails.remembered(for: attachment, api: api) { image = remembered; return }
        let progress = Task { try await Task.sleep(for: .milliseconds(300)); showsProgress = true }
        defer { progress.cancel(); showsProgress = false }
        do {
            image = try await TranscriptThumbnails.image(for: attachment, api: api, reload: attempt > 0)
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }

    static func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return unknown }
        let scale = min(1, maximum.width / size.width, maximum.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

@MainActor
enum TranscriptThumbnails {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 << 20
        return cache
    }()

    static func remembered(for attachment: ChannelAttachment, api: ChannelAPI) -> UIImage? {
        ChannelAttachmentCache.identity(for: attachment, api: api).flatMap { cache.object(forKey: $0 as NSString) }
    }

    /// Fetches into the shared file cache and decodes a bounded, oriented thumbnail off the main actor.
    static func image(for attachment: ChannelAttachment, api: ChannelAPI, reload: Bool) async throws -> UIImage {
        let file = try await ChannelAttachmentCache.shared.file(for: attachment, api: api, reload: reload)
        guard let decoded = await Task.detached(priority: .userInitiated, operation: {
            ChannelImageDecoder.thumbnail(file: file, maxPixelSize: 720)
        }).value else { throw ChannelAttachmentError.invalidImage }
        ChannelImageDecoder.rememberPixelSize(decoded.pixelSize, for: attachment, api: api)
        let image = UIImage(cgImage: decoded.image)
        if let identity = ChannelAttachmentCache.identity(for: attachment, api: api) {
            cache.setObject(image, forKey: identity as NSString,
                            cost: decoded.image.bytesPerRow * decoded.image.height + identity.utf8.count)
        }
        return image
    }
}

private struct TranscriptFileRow: View {
    let attachment: ChannelAttachment
    let api: ChannelAPI
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let address = attachment.url, let url = api.resourceURL(address) { openURL(url) }
        } label: {
            Label {
                Text(attachment.displayName).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "doc")
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(attachment.url == nil)
    }
}

/// A poster that plays only when tapped, in the system player. A missing poster still plays.
private struct TranscriptVideo: View {
    let url: URL
    let name: String
    @ViewState private var poster: UIImage?
    @ViewState private var isPlaying = false

    var body: some View {
        Button { isPlaying = true } label: {
            VStack(spacing: 8) {
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFit()
                        .frame(maxWidth: TranscriptImage.maximum.width, maxHeight: TranscriptImage.maximum.height)
                        .clipShape(.rect(cornerRadius: 10, style: .continuous))
                }
                Label("Play \(name)", systemImage: "play.circle.fill")
                    .font(.subheadline)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: TranscriptImage.maximum.width, minHeight: 44)
            .background(.quaternary, in: .rect(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $isPlaying) { TranscriptPlayer(url: url).ignoresSafeArea() }
        .task(id: url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 320)
            poster = try? await UIImage(cgImage: generator.image(at: .zero).image)
        }
    }
}

private struct TranscriptPlayer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
    }
}
