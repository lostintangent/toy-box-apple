import AppKit
import AVKit
import ChannelClient
import ChannelIntelligence
import ChannelKit
import CryptoKit
import ImageIO
import QuickLook
import SwiftUI
import ToyBoxUI
import UniformTypeIdentifiers

struct TranscriptAttachments: View {
    let attachments: [ChannelAttachment]
    let api: ChannelAPI
    var alignment: UnitPoint = .leading
    /// The message the image viewer pages through when one of these images opens.
    var source: ImageViewer.Source?
    @Environment(ImageViewer.self) private var viewer: ImageViewer?
    @ViewState private var thumbnailFrames = ImageViewerThumbnailFrames()

    var body: some View {
        let positions = imagePositions
        let images = positions.map { attachments[$0] }
        TranscriptAttachmentStrip(count: attachments.count, alignment: alignment, presented: presentedAttachment) { index in
            let imageIndex = positions.firstIndex(of: index)
            TranscriptAttachment(attachment: attachments[index], api: api,
                                 imageName: imageIndex.map {
                                     attachments[index].imageName(index: $0, count: positions.count)
                                 },
                                 viewing: source.flatMap { source in
                                     imageIndex.map { imageIndex in
                                         TranscriptAttachmentViewing(source: source, images: images,
                                                                     imageIndex: imageIndex, frames: thumbnailFrames)
                                     }
                                 })
        }
    }

    private var imagePositions: [Int] { attachments.indices.filter { attachments[$0].isImage } }

    /// The attachment the viewer presents from this message, if any.
    private var presentedAttachment: Int? {
        guard let viewer, let source, let session = viewer.session,
              session.source.messageID == source.messageID else { return nil }
        return imagePositions.dropFirst(viewer.index).first
    }
}

/// How an image tile opens the viewer: its position among its message's images.
struct TranscriptAttachmentViewing {
    let source: ImageViewer.Source
    let images: [ChannelAttachment]
    let imageIndex: Int
    let frames: ImageViewerThumbnailFrames
}

private struct TranscriptAttachment: View {
    let attachment: ChannelAttachment
    let api: ChannelAPI
    /// An image's filename, or its position when it has none.
    var imageName: String?
    var viewing: TranscriptAttachmentViewing?
    @ViewState private var localURL: URL?
    @ViewState private var thumbnail: CGImage?
    @ViewState private var error: String?
    @ViewState private var isLoading = false
    @ViewState private var previewURL: URL?
    @ViewState private var isPlaying = false
    @ViewState private var retry = 0
    @FocusState private var isFocused: Bool
    @AccessibilityFocusState private var isAccessibilityFocused: Bool
    @Environment(ImageViewer.self) private var viewer: ImageViewer?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.channelIntelligence) private var intelligence
    @Environment(\.displayScale) private var displayScale
    @AppStorage(TranscriptIntelligenceSettings.describesImages) private var describesImages = true

    private var name: String { imageName ?? attachment.displayName }

    /// Asked for as the tile appears, while VoiceOver is running.
    private var descriptionRequest: AltTextRequest? {
        guard isImage, TranscriptImageDescriptions.isActive(voiceOver: voiceOver, isOn: describesImages, using: intelligence)
        else { return nil }
        return TranscriptImageDescriptions.request(for: attachment, api: api, file: localURL, priority: .visible)
    }
    private var fileType: UTType? { attachment.contentType }
    private var isImage: Bool { fileType?.conforms(to: .image) == true }
    private var isVideo: Bool { fileType?.conforms(to: .movie) == true }

    /// The tile steps aside only while the viewer's image stands in for it, zooming out of it or
    /// back into it. A crossfade, and so every transition under Reduce Motion, leaves it in place.
    private var isStoodInFor: Bool {
        guard !reduceMotion, let viewer, let viewing, let session = viewer.session, viewer.standsInForTile
        else { return false }
        return session.source.messageID == viewing.source.messageID && viewer.index == viewing.imageIndex
    }

    private func view() {
        guard let viewer, let viewing else {
            previewURL = localURL
            return
        }
        viewer.open(images: viewing.images, at: viewing.imageIndex, source: viewing.source, api: api,
                    thumbnails: viewing.frames)
    }

    var body: some View {
        let thumbnail = thumbnail ?? ChannelThumbnails.remembered(for: attachment, api: api)
        VStack(alignment: .leading, spacing: 5) {
            if isImage, thumbnail != nil || error == nil {
                imageTile(thumbnail)
            } else if isVideo, let localURL {
                Button { isPlaying = true } label: {
                    VStack(spacing: 10) {
                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                                .frame(maxWidth: 240, maxHeight: 120)
                        }
                        Label("Play \(name)", systemImage: "play.circle.fill")
                            .lineLimit(2)
                    }
                    .padding(12)
                    .frame(maxWidth: 240, minHeight: 80)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $isPlaying) { TranscriptVideo(url: localURL, name: name) }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: isImage ? "photo" : isVideo ? "video" : "doc")
                        .font(.title3).foregroundStyle(.secondary)
                    Text(name).lineLimit(2).frame(maxWidth: 170, alignment: .leading)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else if localURL != nil {
                        Button("Open") { previewURL = localURL }
                            .buttonStyle(.borderless)
                    }
                }
                .font(.system(size: 12))
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Couldn't load \(name): \(error)")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { retry += 1 }.buttonStyle(.borderless)
                }
                .font(.caption)
                .frame(maxWidth: 240, alignment: .leading)
            }
        }
        .quickLookPreview($previewURL)
        .task(id: retry) { await load() }
        .contextMenu {
            Button("Quick Look") { previewURL = localURL }.disabled(localURL == nil)
            if let address = attachment.url, let url = api.resourceURL(address) {
                Link("Open in Browser", destination: url)
            }
        }
    }

    /// A loading image holds its final size, from its inline header or from the cached file of an
    /// earlier load, so the row never grows when the preview lands. Only a remote image the app has
    /// never loaded resizes, once.
    private func imageTile(_ thumbnail: CGImage?) -> some View {
        let pixels = ChannelImageDecoder.pixelSize(for: attachment, api: api)
            ?? thumbnail.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 120, height: 90)
        let size = transcriptThumbnailSize(pixels)
        let tile = RoundedRectangle(cornerRadius: 8)
        return Button(action: view) {
            ZStack {
                tile.fill(.quaternary.opacity(0.3))
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                } else {
                    TranscriptDelayedSpinner()
                }
            }
            .frame(width: max(44, size.width), height: max(44, size.height))
            .clipShape(tile)
            // Keeps an edge on screenshots with white or black margins.
            .overlay(tile.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4
                                                             : colorScheme == .dark ? 0.14 : 0.1),
                                       lineWidth: 1))
            .shadow(color: .black.opacity(thumbnail == nil || colorScheme == .dark ? 0 : 0.1), radius: 3, y: 1)
            .onGeometryChange(for: CGRect.self) { proxy in
                // The image's own frame inside the tile, which the viewer zooms out of and back into.
                let frame = proxy.frame(in: .global)
                return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height)
            } action: { frame in
                if let viewing { viewing.frames.frames[viewing.imageIndex] = frame }
            }
        }
        .buttonStyle(.plain)
        .opacity(isStoodInFor ? 0 : 1)
        .focused($isFocused)
        .accessibilityFocused($isAccessibilityFocused)
        .onKeyPress(.return) {
            view()
            return .handled
        }
        .onChange(of: viewer?.focusReturn) { _, focus in
            guard let focus, let viewing, focus.messageID == viewing.source.messageID,
                  focus.index == viewing.imageIndex else { return }
            isFocused = true
            isAccessibilityFocused = true
        }
        .accessibilityLabel("View \(name)")
        .accessibilityValue(thumbnail == nil ? "Loading"
                            : TranscriptImageDescriptions.value(TranscriptImageDescriptions.shared.text(for: descriptionRequest)))
        .help("View \(name)")
        .task(id: descriptionRequest) {
            guard let descriptionRequest else { return }
            await TranscriptImageDescriptions.shared.describe(descriptionRequest, using: intelligence)
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let file = try await ChannelAttachmentCache.shared.file(for: attachment, api: api, reload: retry > 0)
            guard !Task.isCancelled else { return }
            localURL = file
            if isImage {
                let image = try await TranscriptThumbnails.image(at: file, for: attachment, api: api,
                                                                 scale: displayScale, reload: retry > 0)
                guard !Task.isCancelled else { return }
                thumbnail = image
            } else if isVideo {
                let asset = AVURLAsset(url: file)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 320)
                do {
                    let image = try await generator.image(at: .zero).image
                    guard !Task.isCancelled else { return }
                    thumbnail = ChannelThumbnails.remember(image, for: attachment, api: api)
                } catch {
                    // A missing poster must not prevent playback of a valid video.
                    self.error = "Video preview unavailable. Use Play to open the video."
                }
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A loading indicator that appears only after 300 ms, so quick loads never flash a spinner.
struct TranscriptDelayedSpinner: View {
    var controlSize: ControlSize = .small
    @ViewState private var isVisible = false

    var body: some View {
        ZStack {
            if isVisible { ProgressView().controlSize(controlSize) }
        }
        .task {
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            isVisible = true
        }
    }
}

private struct TranscriptVideo: View {
    let name: String
    @ViewState private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    init(url: URL, name: String) {
        self.name = name
        _player = ViewState(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(name).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            VideoPlayer(player: player).frame(minWidth: 560, minHeight: 340)
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}

/// Decoded previews by attachment. A row that is created again, after switching channels, in a
/// second window or when paging, lays out at its final height on its first pass instead of
/// starting as a file chip and growing when its decode lands.
///
/// The shared thumbnails, with the SVG rasterizer ImageIO lacks.
@MainActor
enum TranscriptThumbnails {
    static func image(at file: URL, for attachment: ChannelAttachment, api: ChannelAPI, scale: CGFloat,
                      reload: Bool = false) async throws -> CGImage {
        try await ChannelThumbnails.image(at: file, for: attachment, api: api, scale: scale,
                                          reload: reload, fallback: svg)
    }

    nonisolated static func decode(_ file: URL, scale: CGFloat) throws -> CGImage {
        try ChannelThumbnails.decode(file, scale: scale, fallback: svg).image
    }

    nonisolated private static let svg: ChannelThumbnails.Fallback = { file, bound in
        let decoded = try TranscriptSVGImage.decode(file, maximumPixelSize: bound)
        return (decoded.image, decoded.pixelSize)
    }
}

enum TranscriptSVGImage {
    static let maximumPixelSize = 8192
    struct Decoded {
        let image: CGImage
        let pixelSize: CGSize
    }

    static func decode(_ file: URL, maximumPixelSize: Int) throws -> Decoded {
        let data = try Data(contentsOf: file)
        guard let image = NSImage(data: data) else { throw ChannelAttachmentError.invalidImage }
        let size = image.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw ChannelAttachmentError.invalidImage
        }
        try Task.checkCancellation()
        let edge = CGFloat(min(Self.maximumPixelSize, max(1, maximumPixelSize)))
        let longest = max(size.width, size.height)
        let width = max(1, Int(ceil(size.width / longest * edge)))
        let height = max(1, Int(ceil(size.height / longest * edge)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ChannelAttachmentError.invalidImage
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .copy, fraction: 1)
        guard let bitmap = context.makeImage() else { throw ChannelAttachmentError.invalidImage }
        return Decoded(image: bitmap, pixelSize: size)
    }
}
