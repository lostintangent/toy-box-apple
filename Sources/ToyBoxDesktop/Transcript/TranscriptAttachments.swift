import AppKit
import AVKit
import ChannelClient
import ChannelKit
import CryptoKit
import ImageIO
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The attachment's own filename. Inline images often have none, and a data URL never names one.
func transcriptAttachmentFilename(_ attachment: ChannelAttachment) -> String? {
    if let name = attachment.name, !name.isEmpty { return name }
    guard let address = attachment.url, !address.hasPrefix("data:"),
          let component = URL(string: address)?.lastPathComponent,
          !component.isEmpty, component != "/" else { return nil }
    return component
}

func transcriptAttachmentName(_ attachment: ChannelAttachment) -> String {
    transcriptAttachmentFilename(attachment)
        ?? (attachment.mimeType?.hasPrefix("image/") == true ? "Image" : "Attachment")
}

/// Names an image without a filename by its place among its message's images, as the pane does.
func transcriptImageName(_ attachment: ChannelAttachment, index: Int, count: Int) -> String {
    transcriptAttachmentFilename(attachment) ?? (count > 1 ? "Image \(index + 1) of \(count)" : "Image")
}

func transcriptAttachmentType(_ attachment: ChannelAttachment) -> UTType? {
    attachment.mimeType.flatMap { UTType(mimeType: $0) }
        ?? UTType(filenameExtension: (transcriptAttachmentName(attachment) as NSString).pathExtension)
}

func transcriptAttachmentIsImage(_ attachment: ChannelAttachment) -> Bool {
    transcriptAttachmentType(attachment)?.conforms(to: .image) == true
}

struct TranscriptAttachments: View {
    let attachments: [ChannelAttachment]
    let api: ChannelAPI
    var alignment: UnitPoint = .leading
    /// The message the image viewer pages through when one of these images opens.
    var source: ImageViewer.Source?
    @Environment(ImageViewer.self) private var viewer: ImageViewer?
    @ViewState private var thumbnailFrames = ImageViewerThumbnailFrames()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) { items }
                    // Room for the tiles' shadows inside the strip's clip, without moving its edges.
                    .padding(Self.shadowRoom)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(-Self.shadowRoom)
            // Never, not hidden: with a mouse or "Always" scroll bars, hidden still shows a legacy
            // scroller, which would make an overflowing strip 17 points taller than a fitting one.
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .defaultScrollAnchor(alignment, for: .alignment)
            // The viewer closes into the current image's tile, so the strip keeps that tile in view.
            .onChange(of: presentedAttachment) { _, position in
                guard let position else { return }
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(position) }
            }
        }
    }

    private static let shadowRoom: CGFloat = 4

    private var images: [ChannelAttachment] { attachments.filter(transcriptAttachmentIsImage) }

    /// The attachment the viewer presents from this message, if any.
    private var presentedAttachment: Int? {
        guard let viewer, let source, let session = viewer.session,
              session.source.messageID == source.messageID else { return nil }
        return attachments.indices.filter { transcriptAttachmentIsImage(attachments[$0]) }
            .dropFirst(viewer.index).first
    }

    @ViewBuilder
    private var items: some View {
        let positions = attachments.indices.filter { transcriptAttachmentIsImage(attachments[$0]) }
        ForEach(attachments.indices, id: \.self) { index in
            let imageIndex = positions.firstIndex(of: index)
            TranscriptAttachment(attachment: attachments[index], api: api,
                                 imageName: imageIndex.map {
                                     transcriptImageName(attachments[index], index: $0, count: positions.count)
                                 },
                                 viewing: source.flatMap { source in
                                     imageIndex.map { imageIndex in
                                         TranscriptAttachmentViewing(source: source, images: images,
                                                                     imageIndex: imageIndex, frames: thumbnailFrames)
                                     }
                                 })
            .id(index)
        }
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
    @ViewState private var thumbnail: NSImage?
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

    private var name: String { imageName ?? transcriptAttachmentName(attachment) }
    private var fileType: UTType? { transcriptAttachmentType(attachment) }
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
        let thumbnail = thumbnail ?? TranscriptThumbnails.remembered(for: attachment, api: api)
        VStack(alignment: .leading, spacing: 5) {
            if isImage, thumbnail != nil || error == nil {
                imageTile(thumbnail)
            } else if isVideo, let localURL {
                Button { isPlaying = true } label: {
                    VStack(spacing: 10) {
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().scaledToFit()
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

    /// A loading image holds its final size, from the inline header when there is one, so the row
    /// never grows when the preview lands. Only a remote image of unknown size resizes, once.
    private func imageTile(_ thumbnail: NSImage?) -> some View {
        let pixels = TranscriptThumbnails.pixelSize(for: attachment, api: api)
            ?? thumbnail?.size ?? CGSize(width: 120, height: 90)
        let size = transcriptThumbnailSize(pixels)
        let tile = RoundedRectangle(cornerRadius: 8)
        return Button(action: view) {
            ZStack {
                tile.fill(.quaternary.opacity(0.3))
                if let thumbnail {
                    Image(nsImage: thumbnail)
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
        .accessibilityValue(thumbnail == nil ? "Loading" : "")
        .help("View \(name)")
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let file = try await TranscriptAttachmentCache.shared.file(for: attachment, api: api, reload: retry > 0)
            guard !Task.isCancelled else { return }
            localURL = file
            if isImage {
                let image = try await TranscriptThumbnails.image(at: file, for: attachment, api: api,
                                                                 reload: retry > 0)
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
                    thumbnail = TranscriptThumbnails.remember(image, for: attachment, api: api)
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
    @ViewState private var isVisible = false

    var body: some View {
        ZStack {
            if isVisible { ProgressView().controlSize(.small) }
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

enum AttachmentError: LocalizedError, Equatable {
    case invalidAddress, invalidData, invalidImage, response(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "This attachment has no supported resource address."
        case .invalidData: "This attachment contains invalid data."
        case .invalidImage: "The image could not be decoded."
        case .response(let status): "The server returned HTTP \(status)."
        }
    }
}

actor TranscriptAttachmentCache {
    static let shared = TranscriptAttachmentCache()
    private var inFlight: [String: Task<URL, any Error>] = [:]

    /// The remote address or inline payload that identifies an attachment's content.
    static func identity(for attachment: ChannelAttachment, api: ChannelAPI) -> String? {
        let identity = attachment.url.flatMap(api.resourceURL)?.absoluteString ?? attachment.base64 ?? ""
        return identity.isEmpty ? nil : identity
    }

    private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToyBoxDesktop-Attachments", isDirectory: true)

    /// Where an attachment's content is cached, named by the digest of its identity.
    static func destination(for attachment: ChannelAttachment, api: ChannelAPI) -> URL? {
        guard let identity = identity(for: attachment, api: api) else { return nil }
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let type = attachment.mimeType.flatMap { UTType(mimeType: $0) }
        let suffix = (attachment.name as NSString?)?.pathExtension.nilIfEmpty
            ?? attachment.url.flatMap(api.resourceURL)?.pathExtension.nilIfEmpty
            ?? type?.preferredFilenameExtension ?? "data"
        return directory.appendingPathComponent(key).appendingPathExtension(suffix)
    }

    /// An attachment's cached file when an earlier load already wrote it.
    static func cachedFile(for attachment: ChannelAttachment, api: ChannelAPI) -> URL? {
        destination(for: attachment, api: api).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    func file(for attachment: ChannelAttachment, api: ChannelAPI, reload: Bool = false) async throws -> URL {
        let remote = attachment.url.flatMap(api.resourceURL)
        guard let destination = Self.destination(for: attachment, api: api) else { throw AttachmentError.invalidAddress }
        let key = destination.deletingPathExtension().lastPathComponent
        if let task = inFlight[key] { return try await task.value }
        let task = Task<URL, any Error> {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if !reload && FileManager.default.fileExists(atPath: destination.path) { return destination }
            if let remote {
                let (temporary, response) = try await URLSession.shared.download(from: remote)
                guard let response = response as? HTTPURLResponse else { throw AttachmentError.invalidData }
                guard (200..<300).contains(response.statusCode) else {
                    throw AttachmentError.response(response.statusCode)
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
            } else if let base64 = attachment.base64, let data = Data(base64Encoded: base64) {
                try data.write(to: destination, options: .atomic)
            } else {
                throw AttachmentError.invalidData
            }
            return destination
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

/// Decoded previews by attachment. A row that is created again, after switching channels, in a
/// second window or when paging, lays out at its final height on its first pass instead of
/// starting as a file chip and growing when its decode lands.
///
/// Previews are keyed by the address or inline payload itself rather than its digest. `body` looks
/// them up, and hashing a multi-megabyte payload there costs milliseconds, while an `NSString`
/// lookup samples the string and compares the payload's storage.
@MainActor
enum TranscriptThumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    private static let pixelSizes: NSCache<NSString, NSValue> = {
        let cache = NSCache<NSString, NSValue>()
        cache.countLimit = 512
        return cache
    }()

    /// An inline image's oriented pixel size, read from the start of its payload without decoding it.
    static func pixelSize(for attachment: ChannelAttachment, api: ChannelAPI) -> CGSize? {
        guard attachment.url.flatMap(api.resourceURL) == nil,
              let payload = attachment.base64, !payload.isEmpty else { return nil }
        let key = payload as NSString
        let size = pixelSizes.object(forKey: key)?.sizeValue ?? {
            let size = headerPixelSize(base64: payload) ?? .zero
            pixelSizes.setObject(NSValue(size: size), forKey: key)
            return size
        }()
        return size == .zero ? nil : size
    }

    nonisolated static func headerPixelSize(base64 payload: String) -> CGSize? {
        // 64K characters are 48 KB of image, past the size fields of PNG, GIF and EXIF-laden JPEGs.
        let prefix = Data(payload.utf8.prefix(65_536))
        guard let data = Data(base64Encoded: prefix) else { return nil }
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, prefix.count == payload.utf8.count)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        return orientedPixelSize(properties)
    }

    nonisolated static func orientedPixelSize(_ properties: [CFString: Any]) -> CGSize? {
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        // Orientations 5 through 8 rotate a quarter turn, as the decoded thumbnail does.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    static func remembered(for attachment: ChannelAttachment, api: ChannelAPI) -> NSImage? {
        TranscriptAttachmentCache.identity(for: attachment, api: api).flatMap { cache.object(forKey: $0 as NSString) }
    }

    /// Decoding a large image takes tens of milliseconds, so it runs off the main actor.
    static func image(at file: URL, for attachment: ChannelAttachment, api: ChannelAPI,
                      reload: Bool = false) async throws -> NSImage {
        if !reload, let image = remembered(for: attachment, api: api) { return image }
        let image = try await Task.detached(priority: .userInitiated) { try decode(file) }.value
        return remember(image, for: attachment, api: api)
    }

    private nonisolated static func decode(_ file: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else {
            throw AttachmentError.invalidImage
        }
        return image
    }

    static func remember(_ image: CGImage, for attachment: ChannelAttachment, api: ChannelAPI) -> NSImage {
        let thumbnail = NSImage(cgImage: image, size: .zero)
        if let identity = TranscriptAttachmentCache.identity(for: attachment, api: api) {
            // The cache keeps its key alive, which for an inline image is the whole payload.
            cache.setObject(thumbnail, forKey: identity as NSString,
                            cost: image.bytesPerRow * image.height + identity.utf8.count)
        }
        return thumbnail
    }
}

func transcriptThumbnailSize(_ original: CGSize) -> CGSize {
    guard original.width > 0, original.height > 0,
          original.width.isFinite, original.height.isFinite else { return CGSize(width: 44, height: 44) }
    let scale = min(1, 240 / original.width, 160 / original.height)
    return CGSize(width: original.width * scale, height: original.height * scale)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
