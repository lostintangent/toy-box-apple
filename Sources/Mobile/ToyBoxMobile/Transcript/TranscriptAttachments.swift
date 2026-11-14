import AVKit
import ChannelClient
import ChannelIntelligence
import ChannelKit
import SwiftUI
import ToyBoxUI

struct TranscriptAttachments: View {
    let attachments: [ChannelAttachment]
    let api: ChannelAPI
    let alignment: UnitPoint
    /// The message the images belong to, which the gallery names.
    let source: TranscriptImageSource
    /// Set only on a message that didn't send, so one with only images can still be deleted.
    var delete: (() -> Void)?
    @Environment(TranscriptGallery.self) private var gallery: TranscriptGallery?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        let images = TranscriptGallery.images(in: attachments)
        TranscriptAttachmentStrip(count: attachments.count, alignment: alignment, presented: presented) { offset in
            if let delete {
                tile(attachments[offset], at: offset, images: images)
                    .contextMenu { Button("Delete", systemImage: "trash", role: .destructive, action: delete) }
            } else {
                tile(attachments[offset], at: offset, images: images)
            }
        }
    }

    @ViewBuilder
    private func tile(_ attachment: ChannelAttachment, at offset: Int, images: [ChannelAttachment]) -> some View {
        if TranscriptGallery.isGalleryImage(attachment) {
            let position = attachments[..<offset].count(where: TranscriptGallery.isGalleryImage)
            if let gallery {
                TranscriptImage(attachment: attachment, api: api, voiceOver: voiceOver) {
                    gallery.open(images: images, at: position, source: source, api: api)
                }
            } else {
                TranscriptImage(attachment: attachment, api: api, voiceOver: voiceOver)
            }
        } else if attachment.isVideo, let address = attachment.url, let url = api.resourceURL(address) {
            TranscriptVideo(attachment: attachment, url: url, api: api) {
                if attachment.playsInSystemPlayer {
                    TranscriptPlayer(url: url).ignoresSafeArea()
                } else {
                    TranscriptWebPlayer(url: url, name: attachment.displayName)
                }
            }
        } else {
            TranscriptFileRow(attachment: attachment, api: api)
        }
    }

    /// The attachment the gallery presents from this message, if any.
    private var presented: Int? {
        guard let session = gallery?.session, session.source.messageID == source.messageID else { return nil }
        return attachments.indices.filter { TranscriptGallery.isGalleryImage(attachments[$0]) }
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
    @AppStorage(IntelligenceSettings.describesImages) private var describesImages = true
    @ViewState private var file: URL?
    @ViewState private var image: CGImage?
    @ViewState private var failed = false
    @ViewState private var attempt = 0

    var body: some View {
        let shown = image ?? ChannelThumbnails.remembered(for: attachment, api: api)
        let request = descriptionRequest(isLoaded: shown != nil)
        // An image that couldn't load keeps its tile, and tapping it tries again.
        let isBroken = failed && shown == nil
        Group {
            if isBroken {
                Button { failed = false; attempt += 1 } label: { thumbnail(shown) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Tries again")
            } else if let open {
                Button(action: open) { thumbnail(shown) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the image")
            } else {
                thumbnail(shown)
            }
        }
        .accessibilityLabel(attachment.displayName)
        .accessibilityValue(isBroken ? "Couldn't load" : TranscriptImageDescriptionSession.value(
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
        let size = ChannelThumbnails.boxSize(fitting: ChannelImageDecoder.pixelSize(for: attachment, api: api)
            ?? shown.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 120, height: 90))
        return ZStack {
            if let shown {
                Image(decorative: shown, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
                if failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    DelayedProgressView()
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.transcriptAttachment)
        .transcriptAttachmentEdge(.transcriptAttachment)
    }

    private func load() async {
        guard image == nil else { return }
        do {
            let loaded = try await ChannelThumbnails.load(for: attachment, api: api, scale: displayScale,
                                                          reload: attempt > 0)
            try Task.checkCancellation()
            image = loaded.image
            file = loaded.file
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}

private struct TranscriptWebPlayer: View {
    let url: URL
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TranscriptWebVideo(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
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
