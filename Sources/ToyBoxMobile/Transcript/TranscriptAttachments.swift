import AVKit
import ChannelClient
import ChannelIntelligence
import ChannelKit
import QuickLook
import SwiftUI
import ToyBoxUI
import UniformTypeIdentifiers

struct TranscriptAttachments: View {
    let attachments: [ChannelAttachment]
    let api: ChannelAPI
    let alignment: UnitPoint
    /// The message the images belong to, which the gallery names.
    let source: TranscriptGalleryPresenter.Source
    @Environment(TranscriptGalleryPresenter.self) private var gallery: TranscriptGalleryPresenter?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        let images = TranscriptGalleryPresenter.images(in: attachments)
        TranscriptAttachmentStrip(count: attachments.count, alignment: alignment, presented: presented) { offset in
            let attachment = attachments[offset]
            if TranscriptGalleryPresenter.isGalleryImage(attachment) {
                let position = attachments[..<offset].count(where: TranscriptGalleryPresenter.isGalleryImage)
                if let gallery {
                    TranscriptImage(attachment: attachment, api: api, voiceOver: voiceOver) {
                        gallery.open(images: images, at: position, source: source, api: api)
                    }
                } else {
                    TranscriptImage(attachment: attachment, api: api, voiceOver: voiceOver)
                }
            } else if attachment.contentType?.conforms(to: .movie) == true,
                      let address = attachment.url, let url = api.resourceURL(address) {
                TranscriptVideo(url: url, name: attachment.displayName)
            } else {
                TranscriptFileRow(attachment: attachment, api: api)
            }
        }
    }

    /// The attachment the gallery presents from this message, if any.
    private var presented: Int? {
        guard let session = gallery?.session, session.source.messageID == source.messageID else { return nil }
        return attachments.indices.filter { TranscriptGalleryPresenter.isGalleryImage(attachments[$0]) }
            .dropFirst(session.index).first
    }
}

/// An image that reserves its box from the header before it decodes, so arriving pixels never
/// resize it.
struct TranscriptImage: View {
    let attachment: ChannelAttachment
    let api: ChannelAPI
    let voiceOver: Bool
    var open: (() -> Void)?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.channelIntelligence) private var intelligence
    @AppStorage(TranscriptIntelligenceSettings.describesImages) private var describesImages = true
    @ViewState private var file: URL?
    @ViewState private var image: CGImage?
    @ViewState private var failed = false
    @ViewState private var showsProgress = false
    @ViewState private var attempt = 0

    var body: some View {
        let shown = image ?? ChannelThumbnails.remembered(for: attachment, api: api)
        let request = descriptionRequest(isLoaded: shown != nil)
        Group {
            if let open {
                Button(action: open) { thumbnail(shown) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the image")
            } else {
                thumbnail(shown)
            }
        }
        .accessibilityLabel(attachment.displayName)
        .accessibilityValue(TranscriptImageDescriptionSession.value(
            TranscriptImageDescriptionSession.shared.text(for: request)))
        .task(id: attempt) { await load() }
        .task(id: request) {
            guard let request else { return }
            await TranscriptImageDescriptionSession.shared.describe(request, using: intelligence)
        }
    }

    private func descriptionRequest(isLoaded: Bool) -> AltTextRequest? {
        guard isLoaded,
              TranscriptImageDescriptionSession.isActive(voiceOver: voiceOver, isOn: describesImages, using: intelligence)
        else { return nil }
        return TranscriptImageDescriptionSession.request(
            for: attachment, api: api, file: file ?? ChannelAttachmentCache.cachedFile(for: attachment, api: api),
            priority: .visible)
    }

    private func thumbnail(_ shown: CGImage?) -> some View {
        let size = transcriptThumbnailSize(ChannelImageDecoder.pixelSize(for: attachment, api: api)
            ?? shown.map { CGSize(width: $0.width, height: $0.height) } ?? .zero)
        return ZStack {
            if let shown {
                Image(decorative: shown, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
                if failed {
                    Button("Retry", systemImage: "arrow.clockwise") { failed = false; attempt += 1 }
                        .labelStyle(.iconOnly)
                        .font(.footnote)
                        .frame(minWidth: 44, minHeight: 44)
                } else if showsProgress {
                    ProgressView()
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
    }

    private func load() async {
        guard image == nil else { return }
        if attempt == 0,
           let remembered = ChannelThumbnails.remembered(for: attachment, api: api, scale: displayScale) {
            image = remembered
            return
        }
        let progress = Task { try await Task.sleep(for: .milliseconds(300)); showsProgress = true }
        defer { progress.cancel(); showsProgress = false }
        do {
            let file = try await ChannelAttachmentCache.shared.file(for: attachment, api: api, reload: attempt > 0)
            let image = try await ChannelThumbnails.image(at: file, for: attachment, api: api, scale: displayScale,
                                                          reload: attempt > 0)
            try Task.checkCancellation()
            self.image = image
            self.file = file
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}

/// Opens the file in Quick Look from the shared attachment cache, inline or remote.
private struct TranscriptFileRow: View {
    let attachment: ChannelAttachment
    let api: ChannelAPI
    @ViewState private var preview: URL?
    @ViewState private var isLoading = false
    @ViewState private var failed = false

    var body: some View {
        Button {
            Task { await open() }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.displayName).lineLimit(1).truncationMode(.middle)
                    if failed {
                        Text("Couldn't open. Tap to try again.").font(.caption).foregroundStyle(.red)
                    } else if let kind = attachment.contentType?.localizedDescription {
                        Text(kind).font(.caption).foregroundStyle(TranscriptInk.secondary)
                    }
                }
                // A long name truncates instead of widening the row past an image's width.
                .frame(maxWidth: 200, alignment: .leading)
            } icon: {
                if isLoading { ProgressView() } else { Image(systemName: "doc") }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .quickLookPreview($preview)
    }

    private func open() async {
        isLoading = true
        defer { isLoading = false }
        do {
            preview = try await ChannelAttachmentCache.shared.file(for: attachment, api: api, reload: failed)
            failed = false
        } catch {
            failed = true
        }
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
                        .frame(maxWidth: 240, maxHeight: 160)
                        .clipShape(.rect(cornerRadius: 10, style: .continuous))
                }
                Label("Play \(name)", systemImage: "play.circle.fill")
                    .font(.subheadline)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: 240, minHeight: 44)
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
