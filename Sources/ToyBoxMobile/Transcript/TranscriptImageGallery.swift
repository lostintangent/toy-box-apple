import ChannelClient
import ChannelIntelligence
import ChannelKit
import QuickLook
import SwiftUI
import ToyBoxUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Which message's images the gallery shows. Shell keeps one per channel and shows
/// `TranscriptImageGallery` over the conversation while `session` is set.
@MainActor @Observable
final class TranscriptGalleryPresenter {
    struct Source: Equatable {
        var messageID: String
        var sender: String
        var timestamp: String
    }

    struct Session: Identifiable {
        let id = UUID()
        let source: Source
        let images: [ChannelAttachment]
        let api: ChannelAPI
        fileprivate(set) var index: Int
        /// The last move's direction, so the page change slides the way it went.
        fileprivate(set) var direction = 0

        var canShowPrevious: Bool { index > 0 }
        var canShowNext: Bool { index < images.count - 1 }
        var image: ChannelAttachment { images[index] }
    }

    private(set) var session: Session?

    init() {}

    /// Opens the message's images at the tapped one. The gallery never wraps.
    func open(images: [ChannelAttachment], at index: Int, source: Source, api: ChannelAPI) {
        guard !images.isEmpty else { return }
        session = Session(source: source, images: images, api: api, index: min(max(0, index), images.count - 1))
    }

    func close() { session = nil }

    func move(by offset: Int) {
        guard var session, offset != 0, session.images.indices.contains(session.index + offset) else { return }
        session.index += offset
        session.direction = offset.signum()
        self.session = session
    }

    func select(_ index: Int) {
        guard let session else { return }
        move(by: index - session.index)
    }

    /// The images a message shows inline, in attachment order. The phone has no SVG rasterizer
    /// yet, so an SVG stays a file row.
    static func images(in attachments: [ChannelAttachment]) -> [ChannelAttachment] {
        attachments.filter(isGalleryImage)
    }

    static func isGalleryImage(_ attachment: ChannelAttachment) -> Bool {
        guard let type = attachment.contentType else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    /// "Today at 5:23 PM · 2 of 4", without the position for a single image.
    static func subtitle(sentAt: Date?, index: Int, count: Int, now: Date = .now,
                         calendar: Calendar = .current) -> String {
        let parts = subtitleParts(sentAt: sentAt, index: index, count: count, now: now, calendar: calendar)
        return [parts.sent, parts.position].compactMap(\.self).joined(separator: " · ")
    }

    static func subtitleParts(sentAt: Date?, index: Int, count: Int, now: Date = .now,
                              calendar: Calendar = .current) -> (sent: String?, position: String?) {
        let sent = sentAt.map { sentAt in
            let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current,
                                        calendar: calendar, timeZone: calendar.timeZone)
            return "\(transcriptDayLabel(sentAt, now: now, calendar: calendar)) at \(sentAt.formatted(time))"
        }
        return (sent, count > 1 ? "\(index + 1) of \(count)" : nil)
    }

    /// "Image 2 of 4 from Lead, plan.png".
    static func accessibilityLabel(_ session: Session) -> String {
        let position = session.images.count > 1 ? " \(session.index + 1) of \(session.images.count)" : ""
        let filename = session.image.filename.map { ", \($0)" } ?? ""
        return "Image\(position) from \(session.source.sender)\(filename)"
    }

    func descriptionRequest(for page: Session, file: URL?, voiceOver: Bool, isOn: Bool,
                            using service: any ChannelIntelligenceService) -> AltTextRequest? {
        guard session?.id == page.id, session?.index == page.index,
              TranscriptImageDescriptionSession.isActive(voiceOver: voiceOver, isOn: isOn, using: service)
        else { return nil }
        return TranscriptImageDescriptionSession.request(for: page.image, api: page.api, file: file, priority: .focused)
    }
}

extension TranscriptImageDescriptionSession {
    static func request(for attachment: ChannelAttachment, api: ChannelAPI, file: URL?,
                        priority: AltTextRequest.Priority) -> AltTextRequest? {
        guard let file, let digest = ChannelAttachmentCache.destination(for: attachment, api: api)?
            .deletingPathExtension().lastPathComponent else { return nil }
        return AltTextRequest(server: api.baseURL, digest: digest, fileURL: file, priority: priority)
    }
}

/// The presented page's canvas and original, for the toolbar's actions.
@MainActor @Observable
final class TranscriptGalleryReader {
    weak var canvas: ArtifactImageScrollView?
    var original: TranscriptGalleryOriginal?
    var preview: URL?

    func original(for session: TranscriptGalleryPresenter.Session) -> TranscriptGalleryOriginal? {
        original.flatMap { $0.session == session.id && $0.index == session.index ? $0 : nil }
    }

    var liveText: ImageAnalysisInteraction? {
        canvas?.imageView.interactions.lazy.compactMap { $0 as? ImageAnalysisInteraction }.first
    }
}

struct TranscriptGalleryOriginal: Equatable {
    var session: UUID
    var index: Int
    /// The cached original, under its own name, for Share and Quick Look.
    var export: URL
    var type: UTType?

    /// A link to the cached original under its own name, so Share and Quick Look show the name
    /// rather than the cache's digest.
    nonisolated static func export(_ file: URL, named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToyBox-Images", isDirectory: true)
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var filename = name.replacingOccurrences(of: "/", with: "-")
        if (filename as NSString).pathExtension.isEmpty { filename += ".\(file.pathExtension)" }
        let destination = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.linkItem(at: file, to: destination) }
        catch { try FileManager.default.copyItem(at: file, to: destination) }
        return destination
    }
}

/// The current image for Share. Its file is exported only when a destination asks for it, so
/// Share stays available while the page is still loading.
struct TranscriptGalleryShareItem: Transferable {
    let attachment: ChannelAttachment
    let api: ChannelAPI
    let name: String

    init(_ session: TranscriptGalleryPresenter.Session) {
        attachment = session.image
        api = session.api
        name = session.image.imageName(index: session.index, count: session.images.count)
    }

    /// The thumbnail the conversation already decoded, so the share sheet never shows a blank.
    var preview: Image {
        ChannelThumbnails.remembered(for: attachment, api: api).map { Image(decorative: $0, scale: 1) }
            ?? Image(systemName: "photo")
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            let file = try await ChannelAttachmentCache.shared.file(for: item.attachment, api: item.api)
            return SentTransferredFile(try TranscriptGalleryOriginal.export(file, named: item.name))
        }
    }
}

struct TranscriptImageGallery: View {
    let presenter: TranscriptGalleryPresenter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @ViewState private var reader = TranscriptGalleryReader()
    @AccessibilityFocusState private var titleFocused: Bool

    static let capsuleClearance: CGFloat = 8 + 60 + 16

    var body: some View {
        if let session = presenter.session {
            gallery(session)
        }
    }

    private func margin(_ session: TranscriptGalleryPresenter.Session) -> EdgeInsets {
        let side: CGFloat = sizeClass == .regular ? 24 : 16
        return EdgeInsets(top: side, leading: side,
                          bottom: session.images.count > 1 ? Self.capsuleClearance : side, trailing: side)
    }

    private func gallery(_ session: TranscriptGalleryPresenter.Session) -> some View {
        // The container keeps the page's identity and transition off the capsule and toolbar.
        ZStack {
            TranscriptGalleryPage(session: session, reader: reader, presenter: presenter, page: move)
                .padding(margin(session))
                .id(session.index)
                .transition(pageTransition(session.direction))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .bottom) {
                if session.images.count > 1 {
                    TranscriptGalleryStrip(session: session, select: select, move: move)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .background {
                Button("Close", action: escape)
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                    .accessibilityHidden(true)
                Button("Copy", action: copy)
                    .keyboardShortcut("c")
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .navigationBarBackButtonHidden()
            .toolbar { toolbar(session) }
            .quickLookPreview($reader.preview)
            .task(id: session.index) { titleFocused = true }
    }

    private func pageTransition(_ direction: Int) -> AnyTransition {
        guard !reduceMotion, direction != 0 else { return .opacity }
        let offset: CGFloat = direction > 0 ? 40 : -40
        return .asymmetric(insertion: .offset(x: offset).combined(with: .opacity),
                           removal: .offset(x: -offset).combined(with: .opacity))
    }

    @ToolbarContentBuilder
    private func toolbar(_ session: TranscriptGalleryPresenter.Session) -> some ToolbarContent {
        let original = reader.original(for: session)
        ToolbarItem(placement: .topBarLeading) {
            Button("Back to Conversation", systemImage: "chevron.backward") { presenter.close() }
                .labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .principal) {
            let sentAt = ChannelDates.date(session.source.timestamp)
            let subtitle = TranscriptGalleryPresenter.subtitle(sentAt: sentAt, index: session.index,
                                                               count: session.images.count)
            let parts = TranscriptGalleryPresenter.subtitleParts(sentAt: sentAt, index: session.index,
                                                                 count: session.images.count)
            VStack(spacing: 2) {
                Text(session.source.sender).font(.headline).lineLimit(1)
                // Only the time truncates, so the position stays readable at large text sizes.
                HStack(spacing: 0) {
                    if let sent = parts.sent { Text(sent).lineLimit(1) }
                    if let position = parts.position {
                        Text(parts.sent == nil ? position : " · \(position)").fixedSize()
                    }
                }
                .font(.caption).foregroundStyle(TranscriptInk.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($titleFocused)
            // Toolbar text stops growing with Dynamic Type, so a long press shows the whole title.
            .accessibilityShowsLargeContentViewer {
                Text("\(session.source.sender)\n\(subtitle)")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            let share = TranscriptGalleryShareItem(session)
            ShareLink(item: share, preview: SharePreview(share.name, image: share.preview)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Menu {
                Button("Copy Image", systemImage: "doc.on.doc") { copyImage() }
                    .disabled(original == nil)
                Button("Quick Look", systemImage: "eye") { reader.preview = original?.export }
                    .disabled(original == nil)
                if let remote = remoteURL(session) {
                    Button("Open in Browser", systemImage: "safari") { openURL(remote) }
                }
                Divider()
                Button("Fit Image", systemImage: "arrow.down.right.and.arrow.up.left") { reader.canvas?.fit() }
                    .disabled(reader.canvas == nil)
                Button("Actual Size", systemImage: "1.magnifyingglass") { reader.canvas?.actualSize() }
                    .disabled(reader.canvas == nil)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func remoteURL(_ session: TranscriptGalleryPresenter.Session) -> URL? {
        guard let address = session.image.url, !address.hasPrefix("data:") else { return nil }
        return session.api.resourceURL(address)
    }

    /// Reduce Motion keeps the page change but makes it an opacity-only crossfade.
    static func pageAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)
    }

    private func move(_ offset: Int) {
        withAnimation(Self.pageAnimation(reduceMotion: reduceMotion)) { presenter.move(by: offset) }
    }

    private func select(_ index: Int) {
        withAnimation(Self.pageAnimation(reduceMotion: reduceMotion)) { presenter.select(index) }
    }

    /// Escape clears a Live Text selection before it closes the gallery.
    private func escape() {
        if let liveText = reader.liveText, liveText.hasActiveTextSelection {
            liveText.resetTextSelection()
        } else {
            presenter.close()
        }
    }

    /// Copy takes the selected text, otherwise the image.
    private func copy() {
        if let liveText = reader.liveText, liveText.hasActiveTextSelection {
            UIPasteboard.general.string = liveText.selectedText
        } else {
            copyImage()
        }
    }

    private func copyImage() {
        guard let session = presenter.session, let original = reader.original(for: session),
              let data = try? Data(contentsOf: original.export, options: .mappedIfSafe) else { return }
        UIPasteboard.general.setData(data, forPasteboardType: (original.type ?? .image).identifier)
    }
}

/// One image: it loads the original, decodes it within a bound and hosts the shared canvas.
private struct TranscriptGalleryPage: View {
    let session: TranscriptGalleryPresenter.Session
    let reader: TranscriptGalleryReader
    let presenter: TranscriptGalleryPresenter
    let page: (Int) -> Void
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.channelIntelligence) private var intelligence
    @AppStorage(TranscriptIntelligenceSettings.describesImages) private var describesImages = true
    @ViewState private var loaded: (image: UIImage, size: CGSize, file: URL)?
    @ViewState private var failure: String?
    @ViewState private var showsProgress = false
    @ViewState private var attempt = 0

    private var descriptionRequest: AltTextRequest? {
        presenter.descriptionRequest(
            for: session, file: loaded?.file, voiceOver: voiceOver, isOn: describesImages, using: intelligence)
    }

    var body: some View {
        ZStack {
            if let loaded {
                TranscriptGalleryCanvas(image: loaded.image, size: loaded.size, file: loaded.file,
                                        title: TranscriptGalleryPresenter.accessibilityLabel(session),
                                        descriptionValue: TranscriptImageDescriptionSession.value(
                                            TranscriptImageDescriptionSession.shared.text(for: descriptionRequest)),
                                        reader: reader, page: page)
            } else if let failure {
                ContentUnavailableView {
                    Label("Couldn't Load Image", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Retry") { self.failure = nil; attempt += 1 }
                }
            } else if showsProgress {
                ProgressView("Loading image...").controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: attempt) { await load() }
        .task(id: descriptionRequest) {
            guard let descriptionRequest else { return }
            await TranscriptImageDescriptionSession.shared.describe(descriptionRequest, using: intelligence)
        }
    }

    private func load() async {
        let attachment = session.image
        let api = session.api
        let index = session.index
        let reload = attempt > 0
        let progress = Task { try await Task.sleep(for: .milliseconds(300)); showsProgress = true }
        defer { progress.cancel(); showsProgress = false }
        do {
            let file = try await ChannelAttachmentCache.shared.file(for: attachment, api: api, reload: reload)
            let name = attachment.imageName(index: index, count: session.images.count)
            let (image, pixelSize, export) = try await Task.detached(priority: .userInitiated) {
                guard let decoded = ChannelImageDecoder.thumbnail(file: file, maxPixelSize: 4096) else {
                    throw ChannelAttachmentError.invalidImage
                }
                return (decoded.image, decoded.pixelSize, try TranscriptGalleryOriginal.export(file, named: name))
            }.value
            try Task.checkCancellation()
            let scale = max(1, displayScale)
            loaded = (UIImage(cgImage: image), CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale),
                      file)
            reader.original = TranscriptGalleryOriginal(session: session.id, index: index, export: export,
                                                       type: attachment.contentType)
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// The shared canvas, plus double-tap between fit and actual size and a swipe that pages at fit.
struct TranscriptGalleryCanvas: UIViewRepresentable {
    let image: UIImage
    let size: CGSize
    let file: URL
    let title: String
    let descriptionValue: String
    let reader: TranscriptGalleryReader
    let page: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ArtifactImageScrollView {
        let view = ArtifactImageScrollView()
        context.coordinator.install(on: view)
        configure(view, context: context)
        return view
    }

    func updateUIView(_ view: ArtifactImageScrollView, context: Context) { configure(view, context: context) }

    private func configure(_ view: ArtifactImageScrollView, context: Context) {
        context.coordinator.page = page
        context.coordinator.animates = !context.environment.accessibilityReduceMotion
        view.configure(image: image, size: size, file: file, title: title)
        view.imageView.accessibilityValue = descriptionValue
        reader.canvas = view
    }

    static func dismantleUIView(_ view: ArtifactImageScrollView, coordinator: Coordinator) { view.stop() }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var view: ArtifactImageScrollView?
        var page: (Int) -> Void = { _ in }
        var animates = true
        private var doubleTap: UITapGestureRecognizer?

        func install(on view: ArtifactImageScrollView) {
            self.view = view
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            view.addGestureRecognizer(doubleTap)
            self.doubleTap = doubleTap
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
                swipe.direction = direction
                swipe.delegate = self
                view.addGestureRecognizer(swipe)
            }
        }

        private var liveText: ImageAnalysisInteraction? {
            view?.imageView.interactions.lazy.compactMap { $0 as? ImageAnalysisInteraction }.first
        }

        /// Double-tap toggles fit and actual size around the tap. An image that fits at actual
        /// size has nothing to toggle.
        @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            if view.isAtFitScale {
                guard view.minimumZoomScale < 1 else { return }
                let point = gesture.location(in: view.imageView)
                let size = view.bounds.size
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), animated: animates)
            } else {
                view.setZoomScale(view.minimumZoomScale, animated: animates)
            }
        }

        @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
            page(gesture.direction == .left ? 1 : -1)
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let view else { return false }
            // Live Text keeps its own taps and drags.
            if let liveText, liveText.hasInteractiveItem(at: gesture.location(in: view.imageView)) { return false }
            if gesture === doubleTap { return true }
            return view.isAtFitScale && liveText?.hasActiveTextSelection != true
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gesture !== doubleTap
        }
    }
}

/// The glass capsule of thumbnails between Previous and Next, shown only for several images.
private struct TranscriptGalleryStrip: View {
    let session: TranscriptGalleryPresenter.Session
    let select: (Int) -> Void
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button { move(-1) } label: {
                Label("Previous Image", systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .disabled(!session.canShowPrevious)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(session.images.indices, id: \.self) { index in
                            thumbnail(index)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: session.index, initial: true) { _, index in proxy.scrollTo(index, anchor: .center) }
            }
            .frame(maxWidth: CGFloat(min(9, session.images.count)) * 50 - 6)
            Button { move(1) } label: {
                Label("Next Image", systemImage: "chevron.forward")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .disabled(!session.canShowNext)
        }
        .buttonStyle(.plain)
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Images")
    }

    private func thumbnail(_ index: Int) -> some View {
        let selected = index == session.index
        let attachment = session.images[index]
        return Button { select(index) } label: {
            TranscriptGalleryThumbnail(attachment: attachment, api: session.api)
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 6))
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 2) }
                }
                .padding(2)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(attachment.imageName(index: index, count: session.images.count)), \(index + 1) of \(session.images.count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .id(index)
    }
}

/// The transcript's own thumbnail, which the conversation usually decoded already.
private struct TranscriptGalleryThumbnail: View {
    let attachment: ChannelAttachment
    let api: ChannelAPI
    @Environment(\.displayScale) private var displayScale
    @ViewState private var image: CGImage?

    var body: some View {
        ZStack {
            if let image = image ?? ChannelThumbnails.remembered(for: attachment, api: api) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task {
            guard ChannelThumbnails.remembered(for: attachment, api: api) == nil else { return }
            guard let file = try? await ChannelAttachmentCache.shared.file(for: attachment, api: api) else { return }
            image = try? await ChannelThumbnails.image(at: file, for: attachment, api: api, scale: displayScale)
        }
    }
}
