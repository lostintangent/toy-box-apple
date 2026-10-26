import AppKit
import ChannelClient
import ChannelIntelligence
import ChannelKit
import ImageIO
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// The window's in-place image viewer. A transcript tile opens it on its message's images, the
/// canvas presents it over the detail column, and Shell routes the viewing toolbar and the zoom
/// and close commands through it. One viewer serves one window.
@MainActor @Observable
final class ImageViewer {
    /// The message whose images the viewer pages through.
    struct Source: Equatable, Sendable {
        var messageID: String
        var sender: String
        var timestamp: String

        init(messageID: String, sender: String, timestamp: String) {
            self.messageID = messageID
            self.sender = sender
            self.timestamp = timestamp
        }

        init(message: ChannelMessage, agents: [ChannelAgent]) {
            let sender = switch message.sender.type {
            case "user": "You"
            case "agent": agents.first { $0.id == message.sender.agentId }?.name ?? "Agent"
            default: "Toy Box"
            }
            self.init(messageID: message.id, sender: sender, timestamp: message.timestamp)
        }
    }

    /// What the viewing toolbar shows: the sender as its title and a preformatted subtitle.
    struct Presentation: Equatable {
        var sender: String
        var sentAt: Date?
        /// The zero-based position of the presented image among the message's images.
        var index: Int
        var count: Int
        var filename: String
        /// "Today at 5:23 PM · 2 of 4", without the position for a single image.
        var subtitle: String
    }

    struct Session: Identifiable {
        let id = UUID()
        let source: Source
        let images: [ChannelAttachment]
        let names: [String]
        let api: ChannelAPI
        /// The strip's thumbnail frames, which the canvas zooms out of and back into.
        let thumbnails: ImageViewerThumbnailFrames?
        let openedFrom: CGRect?
    }

    struct Item {
        var file: URL?
        var image: NSImage?
        var bitmap: CGImage?
        /// The image's Live Text, analyzed once it's presented and kept for the session.
        var analysis: ImageAnalysis?
        /// How light the image is under the Live Text button.
        var cornerTone: ImageViewerCornerTone?
        /// The raster's oriented pixel size, or the vector's intrinsic logical point size.
        var pixelSize: CGSize?
        var isVector = false
        var failure: String?
        var export: URL?
    }

    /// The canvas's size and the height of the toolbar it extends under.
    struct Layout: Equatable {
        var size: CGSize
        var topInset: CGFloat
        var displayScale: CGFloat = 2
        /// The canvas's origin in global coordinates, where tiles report their frames.
        var origin: CGPoint = .zero
    }

    struct FocusReturn: Equatable {
        let messageID: String
        let index: Int
        let token = UUID()
    }

    static let zoomSteps: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]
    static let maximumZoom: CGFloat = 8
    static let sideMargin: CGFloat = 24
    static let toolbarMargin: CGFloat = 16
    /// 16 above the capsule, the 48-point capsule and 16 below it.
    static let capsuleReserve: CGFloat = 80
    private static let logger = Logger(subsystem: "dev.toybox.desktop", category: "ImageViewer")

    private(set) var session: Session?
    private(set) var index = 0
    private(set) var isClosing = false
    /// The tile the closing image lands in, in global coordinates, or nil when it fades in place.
    private(set) var closingFrame: CGRect?
    private(set) var items: [Int: Item] = [:]
    /// The scale relative to the image's point size, or nil while the image fits the canvas.
    private(set) var zoom: CGFloat?
    /// The image center's offset from the center of the area it fits.
    private(set) var pan: CGSize = .zero
    /// Set when the viewer closes so the current image's thumbnail takes focus back.
    private(set) var focusReturn: FocusReturn?
    var layout: Layout? {
        didSet { if layout != oldValue { refreshVectorRaster() } }
    }
    /// The height of the window's toolbar over the canvas, measured from AppKit because the
    /// overlay's safe area doesn't carry it.
    var toolbarInset: CGFloat = 0
    @ObservationIgnored var reducesMotion = false
    @ObservationIgnored weak var anchorView: NSView?
    @ObservationIgnored private var canvases = 0
    @ObservationIgnored private var loads: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var vectorRasterTask: Task<Void, Never>?
    @ObservationIgnored private var vectorRasterPixels = 0
    /// The Live Text view over the presented image, which holds its text selection.
    @ObservationIgnored weak var liveTextView: ImageAnalysisOverlayView?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private lazy var analyzer = ImageAnalyzer()
    /// The window's recent analyses by attachment digest, most recent last.
    @ObservationIgnored private var analyses: [(key: String, analysis: ImageAnalysis)] = []
    /// Live Text waits for the opening motion, which it couldn't follow.
    private(set) var hasSettledOpening = false
    /// Asks the stage to take keyboard focus back after Live Text handled a click.
    private(set) var keyFocusRequest = 0
    /// Whether the press under way began on Live Text. It's Live Text's to select with, so the
    /// stage's zoom, pan and export drag, which see every press, let it be.
    var isPressingLiveText = false
    /// Lets a paged-to image settle before its analysis starts, so paging through images analyzes
    /// none of the ones passed on the way.
    static let analysisDelay: Duration = .milliseconds(300)
    static let rememberedAnalyses = 8
    static var readsText: Bool { ImageAnalyzer.isSupported }

    init() {}

    // MARK: Presentation

    var presentation: Presentation? {
        guard let session, !isClosing, session.images.indices.contains(index) else { return nil }
        let sentAt = ChannelDates.date(session.source.timestamp)
        return Presentation(sender: session.source.sender, sentAt: sentAt, index: index,
                            count: session.images.count, filename: session.names[index],
                            subtitle: Self.subtitle(sentAt: sentAt, index: index, count: session.images.count))
    }

    nonisolated static func subtitle(sentAt: Date?, index: Int, count: Int, now: Date = .now,
                                     calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let sentAt {
            let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current,
                                        calendar: calendar, timeZone: calendar.timeZone)
            parts.append("\(transcriptDayLabel(sentAt, now: now, calendar: calendar)) at \(sentAt.formatted(time))")
        }
        if count > 1 { parts.append("\(index + 1) of \(count)") }
        return parts.joined(separator: " · ")
    }

    /// The accessibility label of the presented image, such as "Image 2 of 4 from Lead, plan.png".
    var accessibilityLabel: String {
        guard let session, session.images.indices.contains(index) else { return "Image" }
        let position = session.images.count > 1 ? " \(index + 1) of \(session.images.count)" : ""
        let filename = session.images[index].filename.map { ", \($0)" } ?? ""
        return "Image\(position) from \(session.source.sender)\(filename)"
    }

    // MARK: Opening, paging and closing

    func open(images: [ChannelAttachment], at index: Int, source: Source, api: ChannelAPI,
              thumbnails: ImageViewerThumbnailFrames? = nil) {
        guard images.indices.contains(index) else { return }
        cancelLoads()
        cancelAnalysis()
        let names = images.indices.map { images[$0].imageName(index: $0, count: images.count) }
        session = Session(source: source, images: images, names: names, api: api, thumbnails: thumbnails,
                          openedFrom: thumbnails?.frames[index])
        self.index = index
        isClosing = false
        hasSettledOpening = false
        closingFrame = nil
        zoom = nil
        pan = .zero
        focusReturn = nil
        items = Dictionary(uniqueKeysWithValues: images.indices.map { position in
            (position, Item(pixelSize: Self.knownPixelSize(of: images[position], api: api),
                            isVector: images[position].contentType?.conforms(to: .svg) == true))
        })
        loadAround(index)
    }

    var canShowPrevious: Bool { session != nil && !isClosing && index > 0 }
    var canShowNext: Bool { session.map { !isClosing && index < $0.images.count - 1 } ?? false }

    func showPrevious() { show(index - 1) }
    func showNext() { show(index + 1) }

    /// Pages to another image of the message, resetting zoom. There is no wrap at the ends.
    func show(_ newIndex: Int) {
        guard let session, !isClosing, newIndex != index, session.images.indices.contains(newIndex) else { return }
        liveTextView?.resetSelection()
        cancelVectorRaster()
        withAnimation(reducesMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)) {
            index = newIndex
            zoom = nil
            pan = .zero
        }
        loadAround(newIndex)
        refreshVectorRaster()
        analyzeCurrent()
    }

    /// The stage reports the end of the opening motion, after which the image is analyzed.
    func openingDidSettle() {
        guard session != nil, !isClosing, !hasSettledOpening else { return }
        hasSettledOpening = true
        analyzeCurrent(after: .zero)
    }

    /// Closes the viewer. With a mounted canvas the image zooms back into its thumbnail first.
    /// Switching channels, a deleted message or a lost channel closes without animation.
    func close(animated: Bool = true) {
        guard let session else { return }
        cancelAnalysis()
        cancelVectorRaster()
        liveTextView?.resetSelection()
        if animated && canvases > 0 {
            closingFrame = layout.flatMap(closingTileFrame(in:))
            isClosing = true
        } else {
            finishClosing(session.id)
        }
    }

    /// Ends a session once its closing transition lands. A newer session is left open.
    func finishClosing(_ id: UUID) {
        guard let session, session.id == id else { return }
        focusReturn = FocusReturn(messageID: session.source.messageID, index: index)
        cancelLoads()
        cancelAnalysis()
        self.session = nil
        items = [:]
        zoom = nil
        pan = .zero
        isClosing = false
        closingFrame = nil
    }

    /// The current image's tile, when at least half of it shows below the toolbar.
    func closingTileFrame(in layout: Layout) -> CGRect? {
        guard let frame = session?.thumbnails?.frames[index], frame.width > 0, frame.height > 0 else { return nil }
        let visible = CGRect(x: layout.origin.x, y: layout.origin.y + layout.topInset, width: layout.size.width,
                             height: max(0, layout.size.height - layout.topInset))
        let shown = frame.intersection(visible)
        guard !shown.isNull, shown.width * shown.height >= frame.width * frame.height / 2 else { return nil }
        return frame
    }

    /// The image zooms out of its tile as it opens and back into it as it closes, and the tile steps
    /// aside only while the image stands in for it. Without a frame the image crossfades over the
    /// tile, as it always does under Reduce Motion.
    var standsInForTile: Bool {
        guard let session, let frame = isClosing ? closingFrame : session.openedFrom else { return false }
        return frame.width > 0 && frame.height > 0
    }

    func canvasAppeared() { canvases += 1 }

    func canvasDisappeared() {
        canvases = max(0, canvases - 1)
        if canvases == 0, isClosing, let session { finishClosing(session.id) }
    }

    // MARK: Fit and zoom

    /// The area an image fits: 24 points from the sides, 16 below the toolbar and 16 above the
    /// capsule, which shows only for two or more images.
    func availableRect(in layout: Layout) -> CGRect {
        let top = layout.topInset + Self.toolbarMargin
        let bottom = (session?.images.count ?? 0) > 1 ? Self.capsuleReserve : Self.sideMargin
        return CGRect(x: Self.sideMargin, y: top, width: max(1, layout.size.width - Self.sideMargin * 2),
                      height: max(1, layout.size.height - top - bottom))
    }

    func pointSize(at index: Int, in layout: Layout) -> CGSize? {
        guard let pixels = items[index]?.pixelSize, pixels.width > 0, pixels.height > 0 else { return nil }
        if items[index]?.isVector == true { return pixels }
        let scale = max(1, layout.displayScale)
        return CGSize(width: pixels.width / scale, height: pixels.height / scale)
    }

    /// The scale that fits an image in the canvas. It never upscales past the image's point size,
    /// so a 2x screenshot shows at its native size and an SVG keeps its natural point size.
    func fitScale(at index: Int, in layout: Layout) -> CGFloat {
        let area = availableRect(in: layout)
        guard let point = pointSize(at: index, in: layout) else { return 1 }
        return min(1, area.width / point.width, area.height / point.height)
    }

    func scale(in layout: Layout) -> CGFloat { zoom ?? fitScale(at: index, in: layout) }

    /// An image's frame in canvas coordinates. Only the current image carries zoom and pan.
    func frame(at index: Int, in layout: Layout) -> CGRect {
        let area = availableRect(in: layout)
        let size: CGSize
        if let point = pointSize(at: index, in: layout) {
            let scale = index == self.index ? scale(in: layout) : fitScale(at: index, in: layout)
            size = CGSize(width: point.width * scale, height: point.height * scale)
        } else {
            // A remote image of unknown size fills the area at its thumbnail's aspect until it decodes.
            let aspect = session.flatMap { session in
                TranscriptThumbnails.remembered(for: session.images[index], api: session.api)?.size
            }.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: 4, height: 3)
            let scale = min(area.width / aspect.width, area.height / aspect.height)
            size = CGSize(width: aspect.width * scale, height: aspect.height * scale)
        }
        let offset = index == self.index ? pan : .zero
        return CGRect(x: area.midX + offset.width - size.width / 2, y: area.midY + offset.height - size.height / 2,
                      width: size.width, height: size.height)
    }

    var isZoomed: Bool { zoom != nil }
    var canZoomIn: Bool {
        guard let layout, session != nil, !isClosing, pointSize(at: index, in: layout) != nil else { return false }
        return scale(in: layout) < Self.maximumZoom - 0.001
    }
    var canZoomOut: Bool { session != nil && !isClosing && zoom != nil }
    var isActualSize: Bool {
        guard let layout, session != nil else { return false }
        return abs(scale(in: layout) - 1) < 0.001
    }

    func zoomIn() {
        guard canZoomIn, let layout else { return }
        let current = scale(in: layout)
        setZoom(Self.zoomSteps.first { $0 > current * 1.001 } ?? Self.maximumZoom, animated: true)
    }

    func zoomOut() {
        guard canZoomOut, let layout else { return }
        let current = scale(in: layout)
        let fit = fitScale(at: index, in: layout)
        let next = Self.zoomSteps.last { $0 < current / 1.001 } ?? fit
        setZoom(next <= fit * 1.001 ? nil : next, animated: true)
    }

    func actualSize() {
        guard let layout, session != nil, !isClosing else { return }
        setZoom(fitScale(at: index, in: layout) >= 0.999 ? nil : 1, animated: true)
    }

    /// Double-click and smart zoom toggle between fit and actual size at a canvas point. An image
    /// already shown at actual size zooms to 2x so the gesture is never inert.
    func toggleZoom(at point: CGPoint) {
        guard let layout, session != nil, !isClosing, pointSize(at: index, in: layout) != nil else { return }
        if zoom != nil { setZoom(nil, animated: true); return }
        setZoom(fitScale(at: index, in: layout) < 0.999 ? 1 : 2, at: point, animated: true)
    }

    /// The scale and pan a pinch starts from.
    struct Magnification: Equatable {
        var scale: CGFloat
        var pan: CGSize
    }

    var magnificationBase: Magnification? {
        guard let layout else { return nil }
        return Magnification(scale: scale(in: layout), pan: pan)
    }

    /// Scales from a pinch's start, keeping the point under the fingers in place. A pinch never
    /// shrinks the image below its fitted size.
    func magnify(by factor: CGFloat, from base: Magnification, at point: CGPoint) {
        guard let layout, session != nil, !isClosing, pointSize(at: index, in: layout) != nil,
              base.scale > 0, factor.isFinite else { return }
        let fit = fitScale(at: index, in: layout)
        let target = min(max(base.scale * factor, fit), Self.maximumZoom)
        let anchored = anchoredPan(base.pan, at: point, by: target / base.scale, in: layout)
        zoom = target <= fit * 1.001 ? nil : target
        pan = zoom == nil ? .zero : clampedPan(anchored, scale: target, in: layout)
        refreshVectorRaster()
    }

    func pan(by delta: CGSize) {
        guard let layout, let zoom else { return }
        pan = clampedPan(CGSize(width: pan.width + delta.width, height: pan.height + delta.height),
                         scale: zoom, in: layout)
    }

    func setPan(_ value: CGSize) {
        guard let layout, let zoom else { return }
        pan = clampedPan(value, scale: zoom, in: layout)
    }

    /// A zoomed image pans only until its edges meet the edges of the area it fits.
    func clampedPan(_ value: CGSize, scale: CGFloat, in layout: Layout) -> CGSize {
        guard let point = pointSize(at: index, in: layout) else { return .zero }
        let area = availableRect(in: layout)
        let limit = CGSize(width: max(0, (point.width * scale - area.width) / 2),
                           height: max(0, (point.height * scale - area.height) / 2))
        return CGSize(width: min(max(value.width, -limit.width), limit.width),
                      height: min(max(value.height, -limit.height), limit.height))
    }

    private func setZoom(_ newZoom: CGFloat?, at point: CGPoint? = nil, animated: Bool) {
        guard let layout else { return }
        let target = newZoom ?? fitScale(at: index, in: layout)
        let current = scale(in: layout)
        let area = availableRect(in: layout)
        let anchored = anchoredPan(pan, at: point ?? CGPoint(x: area.midX, y: area.midY),
                                   by: current > 0 ? target / current : 1, in: layout)
        let change = {
            self.zoom = newZoom
            self.pan = newZoom == nil ? .zero : self.clampedPan(anchored, scale: target, in: layout)
        }
        if animated {
            withAnimation(reducesMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.9),
                          change)
        } else {
            change()
        }
        refreshVectorRaster()
    }

    /// Keeps the image point under `point` in place when the scale changes by `factor`.
    private func anchoredPan(_ pan: CGSize, at point: CGPoint, by factor: CGFloat, in layout: Layout) -> CGSize {
        let area = availableRect(in: layout)
        let anchor = CGSize(width: point.x - area.midX, height: point.y - area.midY)
        return CGSize(width: anchor.width - (anchor.width - pan.width) * factor,
                      height: anchor.height - (anchor.height - pan.height) * factor)
    }

    // MARK: Files

    /// The current image under its real filename, for Share, drag-out and Open in Preview.
    var shareURL: URL? { items[index]?.export }
    var canCopy: Bool { session != nil && items[index]?.image != nil }

    func copyImage() {
        guard let image = items[index]?.image else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// What Copy puts on the pasteboard: the selected Live Text, or else the image.
    var copiedItems: [NSItemProvider] {
        if let text = selectedLiveText { return [NSItemProvider(object: text as NSString)] }
        guard let image = items[index]?.image else { return [] }
        return [NSItemProvider(object: image)]
    }

    // MARK: Live Text

    /// The presented image's analysis, once it has text or a code to interact with.
    var liveText: ImageAnalysis? {
        guard session != nil, !isClosing, hasSettledOpening, let analysis = items[index]?.analysis,
              analysis.hasResults(for: [.text, .machineReadableCode]) else { return nil }
        return analysis
    }

    var selectedLiveText: String? {
        guard let view = liveTextView, view.hasActiveTextSelection, !view.selectedText.isEmpty else { return nil }
        return view.selectedText
    }

    /// Clears a Live Text selection, and reports whether there was one.
    @discardableResult
    func clearLiveTextSelection() -> Bool {
        guard let view = liveTextView, view.hasActiveTextSelection else { return false }
        view.resetSelection()
        return true
    }

    /// Escape lets go of a text selection before it closes the viewer.
    func escape() {
        if !clearLiveTextSelection() { close() }
    }

    func reclaimKeyFocus() { keyFocusRequest += 1 }

    /// Analyzes the presented image for Live Text once it has decoded and settled. Paging or
    /// closing cancels it, and the window remembers its last few results.
    func analyzeCurrent(after delay: Duration = analysisDelay) {
        cancelAnalysis()
        guard let session, !isClosing, hasSettledOpening, Self.readsText,
              let item = items[index], item.analysis == nil, let bitmap = item.bitmap else { return }
        let position = index
        let key = TranscriptAttachmentCache.destination(for: session.images[position], api: session.api)?
            .deletingPathExtension().lastPathComponent
        if let key, let remembered = analyses.firstIndex(where: { $0.key == key }) {
            let entry = analyses.remove(at: remembered)
            analyses.append(entry)
            items[position]?.analysis = entry.analysis
            return
        }
        let id = session.id
        let analyzer = analyzer
        analysisTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            let analysis = try? await analyzer.analyze(bitmap, orientation: .up, configuration: configuration)
            guard let self, !Task.isCancelled, let analysis, self.session?.id == id, self.index == position,
                  !self.isClosing else { return }
            self.analysisTask = nil
            self.items[position]?.analysis = analysis
            if let key { self.remember(analysis, for: key) }
        }
    }

    private func remember(_ analysis: ImageAnalysis, for key: String) {
        analyses.removeAll { $0.key == key }
        analyses.append((key, analysis))
        if analyses.count > Self.rememberedAnalyses { analyses.removeFirst(analyses.count - Self.rememberedAnalyses) }
    }

    var rememberedAnalysisCount: Int { analyses.count }

    private func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
    }

    func openInPreview() {
        guard let url = shareURL else { return }
        let workspace = NSWorkspace.shared
        if let preview = workspace.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            workspace.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration(),
                           completionHandler: nil)
        } else {
            workspace.open(url)
        }
    }

    /// Shows the share picker from the canvas, for the image's accessibility Share action.
    func share() {
        guard let url = shareURL, let view = anchorView else { return }
        let anchor = CGRect(x: view.bounds.midX, y: view.bounds.minY + (layout?.topInset ?? 0), width: 1, height: 1)
        NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    func retry() { load(index, reload: true) }

    private func loadAround(_ index: Int) {
        for position in [index, index + 1, index - 1] { load(position) }
    }

    private func load(_ position: Int, reload: Bool = false) {
        guard let session, session.images.indices.contains(position) else { return }
        if !reload && (loads[position] != nil || items[position]?.image != nil) { return }
        if reload && position == index { cancelVectorRaster() }
        loads[position]?.cancel()
        items[position, default: Item()].failure = nil
        let attachment = session.images[position]
        let name = session.names[position]
        let api = session.api
        let id = session.id
        let pixelsPerPoint = max(1, layout?.displayScale ?? 2)
        let rasterPixels = desiredVectorPixels(at: position)
        loads[position] = Task { [weak self] in
            let result: Result<(URL, CGImage, ImageViewerCornerTone?, CGSize?), any Error>
            do {
                let file = try await TranscriptAttachmentCache.shared.file(for: attachment, api: api, reload: reload)
                let (image, tone, vectorSize) = try await Task.detached(priority: .userInitiated) {
                    let decoded = try ImageViewer.decoded(file, maximumPixelSize: rasterPixels)
                    let image = decoded.image
                    let vectorSize = decoded.vectorSize
                    return (image, ImageViewerCornerTone(image, pixelsPerPoint: pixelsPerPoint), vectorSize)
                }.value
                result = .success((file, image, tone, vectorSize))
            } catch {
                result = .failure(error)
            }
            guard let self, self.session?.id == id else { return }
            self.loads[position] = nil
            switch result {
            case .success(let (file, image, tone, vectorSize)):
                var item = self.items[position] ?? Item()
                item.file = file
                item.image = NSImage(cgImage: image, size: .zero)
                item.bitmap = image
                item.cornerTone = tone
                item.pixelSize = vectorSize ?? item.pixelSize ?? CGSize(width: image.width, height: image.height)
                item.isVector = vectorSize != nil
                item.export = Self.export(file, named: name, replacing: reload)
                item.failure = nil
                self.items[position] = item
                if position == self.index {
                    self.refreshVectorRaster()
                    self.analyzeCurrent()
                }
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                self.items[position, default: Item()].failure = error.localizedDescription
            }
        }
    }

    private func cancelLoads() {
        cancelVectorRaster()
        for task in loads.values { task.cancel() }
        loads = [:]
    }

    /// An inline image's size from its header, or a downloaded image's from its cached file.
    static func knownPixelSize(of attachment: ChannelAttachment, api: ChannelAPI) -> CGSize? {
        TranscriptThumbnails.pixelSize(for: attachment, api: api)
    }

    /// Decodes the full image, oriented, off the main actor. Very large images cap at 8192 pixels.
    nonisolated static func decode(_ file: URL, maximumPixelSize: Int = 8192) throws -> CGImage {
        try decoded(file, maximumPixelSize: maximumPixelSize).image
    }

    private nonisolated static func decoded(_ file: URL, maximumPixelSize: Int) throws
        -> (image: CGImage, vectorSize: CGSize?) {
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let size = TranscriptThumbnails.orientedPixelSize(properties),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: min(8192, max(size.width, size.height)),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) { return (image, nil) }
        let decoded = try TranscriptSVGImage.decode(file, maximumPixelSize: maximumPixelSize)
        return (decoded.image, decoded.pixelSize)
    }

    private func desiredVectorPixels(at position: Int) -> Int {
        guard let layout, items[position]?.pixelSize != nil else { return 2048 }
        let frame = frame(at: position, in: layout)
        let edge = max(frame.width, frame.height) * max(1, layout.displayScale)
        guard edge.isFinite else { return TranscriptSVGImage.maximumPixelSize }
        return min(TranscriptSVGImage.maximumPixelSize, max(1, Int(ceil(min(edge, 8192) / 256)) * 256))
    }

    private func cancelVectorRaster() {
        vectorRasterTask?.cancel()
        vectorRasterTask = nil
        vectorRasterPixels = 0
    }

    private func refreshVectorRaster() {
        guard let session, !isClosing, let item = items[index], item.isVector, let file = item.file,
              let bitmap = item.bitmap else { return }
        let pixels = desiredVectorPixels(at: index)
        guard pixels > max(bitmap.width, bitmap.height), pixels != vectorRasterPixels else { return }
        cancelVectorRaster()
        vectorRasterPixels = pixels
        let id = session.id, position = index
        let pixelsPerPoint = max(1, layout?.displayScale ?? 2)
        vectorRasterTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
                let (image, tone) = try await Task.detached(priority: .userInitiated) {
                    let image = try TranscriptSVGImage.decode(file, maximumPixelSize: pixels).image
                    return (image, ImageViewerCornerTone(image, pixelsPerPoint: pixelsPerPoint))
                }.value
                guard !Task.isCancelled, let self, self.session?.id == id, self.index == position else { return }
                self.items[position]?.image = NSImage(cgImage: image, size: .zero)
                self.items[position]?.bitmap = image
                self.items[position]?.cornerTone = tone
                self.vectorRasterTask = nil
                self.vectorRasterPixels = 0
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.session?.id == id, self.index == position else { return }
                Self.logger.warning("Could not increase SVG image resolution: \(error.localizedDescription, privacy: .public)")
                self.items[position]?.failure = error.localizedDescription
                self.vectorRasterTask = nil
                self.vectorRasterPixels = 0
            }
        }
    }

    /// Links the cached file under the attachment's name, so Share, drag-out and Preview see it.
    nonisolated static func export(_ file: URL, named name: String, replacing: Bool = false) -> URL? {
        var filename = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if (filename as NSString).pathExtension.isEmpty, !file.pathExtension.isEmpty, file.pathExtension != "data" {
            filename += ".\(file.pathExtension)"
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("ToyBoxDesktop-Exports", isDirectory: true)
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent, isDirectory: true)
        let destination = directory.appendingPathComponent(filename)
        if replacing { try? manager.removeItem(at: destination) }
        if manager.fileExists(atPath: destination.path) { return destination }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            do { try manager.linkItem(at: file, to: destination) }
            catch { try manager.copyItem(at: file, to: destination) }
            return destination
        } catch {
            return nil
        }
    }
}

/// A strip's tile frames in global coordinates. Tiles keep them current without invalidating
/// any view, and the viewer reads them when it opens and closes.
@MainActor
final class ImageViewerThumbnailFrames {
    var frames: [Int: CGRect] = [:]
}

/// Shell mounts one canvas over the detail column. It's empty and lets clicks through while no
/// image is open.
struct ImageViewerCanvas: View {
    @Environment(ImageViewer.self) private var viewer

    var body: some View {
        ZStack {
            if let session = viewer.session {
                ImageViewerStage(viewer: viewer, session: session).id(session.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ImageViewerToolbarInset(viewer: viewer).ignoresSafeArea(edges: .top) }
        .allowsHitTesting(viewer.session != nil)
        .onAppear { viewer.canvasAppeared() }
        .onDisappear { viewer.canvasDisappeared() }
    }
}

private struct ImageViewerStage: View {
    let viewer: ImageViewer
    let session: ImageViewer.Session
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.channelIntelligence) private var intelligence
    @AppStorage(TranscriptIntelligenceSettings.describesImages) private var describesImages = true
    @ViewState private var isRevealed = false
    @ViewState private var showsBackdrop = false
    @ViewState private var magnification: ImageViewer.Magnification?
    @ViewState private var panStart: CGSize?
    @ViewState private var capsuleFrame: CGRect = .zero
    @FocusState private var isFocused: Bool
    @AccessibilityFocusState private var isImageFocused: Bool

    private var hairline: Color {
        Color.primary.opacity(contrast == .increased ? 0.4 : colorScheme == .dark ? 0.14 : 0.1)
    }

    private var revealAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.9)
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = ImageViewer.Layout(size: proxy.size,
                                            topInset: max(proxy.safeAreaInsets.top, viewer.toolbarInset),
                                            displayScale: displayScale, origin: proxy.frame(in: .global).origin)
            stage(layout: layout)
                .onChange(of: layout, initial: true) { viewer.layout = layout }
                .onChange(of: viewer.isClosing) { _, closing in
                    if closing { animateClose() }
                }
        }
        // The canvas runs under the glass toolbar but stops at the sidebar, whose glass would
        // otherwise pick up the canvas.
        .ignoresSafeArea(edges: .top)
        .clipped()
        .onAppear {
            viewer.reducesMotion = reduceMotion
            withAnimation(revealAnimation, completionCriteria: .logicallyComplete) {
                isRevealed = true
            } completion: {
                viewer.openingDidSettle()
            }
            withAnimation(.easeOut(duration: 0.2)) { showsBackdrop = true }
            isFocused = true
            isImageFocused = true
        }
        .onChange(of: reduceMotion) { _, value in viewer.reducesMotion = value }
    }

    private func stage(layout: ImageViewer.Layout) -> some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
                .opacity(showsBackdrop ? 1 : 0)
                .contentShape(Rectangle())
            ForEach(session.images.indices, id: \.self) { position in
                page(position, layout: layout)
            }
            ImageViewerLiveText(viewer: viewer, analysis: viewer.liveText,
                                cornerTone: viewer.items[viewer.index]?.cornerTone,
                                imageFrame: viewer.frame(at: viewer.index, in: layout), showsButton: !viewer.isZoomed)
            status(layout: layout)
            if session.images.count > 1 {
                ImageViewerCapsule(viewer: viewer, session: session, hairline: hairline)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .local) } action: { capsuleFrame = $0 }
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(showsBackdrop ? 1 : 0)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(ImageViewerEvents(viewer: viewer, capsuleFrame: capsuleFrame))
        .gesture(MagnifyGesture()
            .onChanged { value in
                if magnification == nil { magnification = viewer.magnificationBase }
                guard let magnification else { return }
                viewer.magnify(by: value.magnification, from: magnification, at: value.startLocation)
            }
            .onEnded { _ in magnification = nil })
        .simultaneousGesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !viewer.isPressingLiveText else { return }
                if panStart == nil { panStart = viewer.pan }
                guard let panStart else { return }
                viewer.setPan(CGSize(width: panStart.width + value.translation.width,
                                     height: panStart.height + value.translation.height))
            }
            .onEnded { _ in panStart = nil }, isEnabled: viewer.isZoomed)
        .onTapGesture(count: 2, coordinateSpace: .local) { point in
            if !viewer.isPressingLiveText { viewer.toggleZoom(at: point) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) { viewer.showPrevious(); return .handled }
        .onKeyPress(.rightArrow) { viewer.showNext(); return .handled }
        .onKeyPress(.space) { viewer.close(); return .handled }
        .onExitCommand { viewer.escape() }
        .onCopyCommand { viewer.copiedItems }
        .onChange(of: viewer.keyFocusRequest) { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private func page(_ position: Int, layout: ImageViewer.Layout) -> some View {
        let isCurrent = position == viewer.index
        let fitted = viewer.frame(at: position, in: layout)
        let source = isCurrent && !reduceMotion ? sourceFrame(in: layout) : nil
        let frame = !isRevealed ? source ?? fitted : fitted
        let corner: CGFloat = isRevealed ? 6 : 8
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let travel: CGFloat = reduceMotion ? 0 : position < viewer.index ? -40 : position > viewer.index ? 40 : 0
        let isVisible = isCurrent && (isRevealed || source != nil)
        picture(position)
            .frame(width: frame.width, height: frame.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(hairline, lineWidth: 1))
            .overlay {
                if isCurrent && !viewer.isZoomed && !viewer.isPressingLiveText,
                   let url = viewer.items[position]?.export, let image = viewer.items[position]?.image {
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() } preview: {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 160, maxHeight: 160)
                        }
                }
            }
            // A zoomed image can be many times the canvas, and a shadow there costs more than it shows.
            .shadow(color: .black.opacity(colorScheme == .dark || viewer.isZoomed ? 0 : 0.12), radius: 12, y: 4)
            // Reduce Motion is a pure crossfade.
            .scaleEffect(isRevealed || source != nil || reduceMotion ? 1 : 0.94)
            .position(x: frame.midX + travel, y: frame.midY)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isCurrent)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(viewer.accessibilityLabel)
            .accessibilityValue(isCurrent && viewer.items[position]?.image != nil
                                ? TranscriptImageDescriptions.value(TranscriptImageDescriptions.shared.text(
                                    for: descriptionRequest(position))) : "")
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: "Next") { viewer.showNext() }
            .accessibilityAction(named: "Previous") { viewer.showPrevious() }
            .accessibilityAction(named: "Copy") { viewer.copyImage() }
            .accessibilityAction(named: "Share") { viewer.share() }
            .accessibilityAction(named: "Close") { viewer.close() }
            .accessibilityAction(.escape) { viewer.escape() }
            .accessibilityFocused($isImageFocused)
            // Hiding comes last. Applied before the element, the hidden page gains a new outer
            // element with the current image's label.
            .accessibilityHidden(!isCurrent)
            .task(id: isCurrent ? descriptionRequest(position) : nil) {
                guard isCurrent, let request = descriptionRequest(position) else { return }
                await TranscriptImageDescriptions.shared.describe(request, using: intelligence)
            }
    }

    /// The current image goes ahead of tiles in the description queue.
    private func descriptionRequest(_ position: Int) -> AltTextRequest? {
        guard TranscriptImageDescriptions.shared.isActive(using: intelligence, isOn: describesImages) else { return nil }
        return TranscriptImageDescriptions.request(for: session.images[position], api: session.api,
                                                   file: viewer.items[position]?.file, priority: .focused)
    }

    @ViewBuilder
    private func picture(_ position: Int) -> some View {
        if let image = viewer.items[position]?.image
            ?? TranscriptThumbnails.remembered(for: session.images[position], api: session.api) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else if viewer.items[position]?.failure == nil {
            Rectangle().fill(.quaternary.opacity(0.3))
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func status(layout: ImageViewer.Layout) -> some View {
        let item = viewer.items[viewer.index]
        if let failure = item?.failure, item?.image == nil {
            VStack(spacing: 8) {
                Text("Couldn't Load Image").font(.headline)
                Text(failure).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { viewer.retry() }.padding(.top, 4)
            }
            .frame(maxWidth: 320)
            .position(x: layout.size.width / 2, y: layout.size.height / 2)
            .opacity(showsBackdrop ? 1 : 0)
        } else if item?.image == nil {
            let frame = viewer.frame(at: viewer.index, in: layout)
            TranscriptDelayedSpinner()
                .position(x: frame.midX, y: frame.midY)
                .opacity(isRevealed ? 1 : 0)
        }
    }

    /// The tile the current image opens from or closes into, in canvas coordinates.
    private func sourceFrame(in layout: ImageViewer.Layout) -> CGRect? {
        guard viewer.standsInForTile, let global = viewer.isClosing ? viewer.closingFrame : session.openedFrom
        else { return nil }
        return global.offsetBy(dx: -layout.origin.x, dy: -layout.origin.y)
    }

    private func animateClose() {
        let id = session.id
        withAnimation(.easeOut(duration: 0.2)) { showsBackdrop = false }
        withAnimation(revealAnimation, completionCriteria: .logicallyComplete) {
            isRevealed = false
        } completion: {
            viewer.finishClosing(id)
        }
    }
}

private struct ImageViewerCapsule: View {
    let viewer: ImageViewer
    let session: ImageViewer.Session
    let hairline: Color

    private static let thumbnail: CGFloat = 32
    private static let spacing: CGFloat = 6
    private static let visibleThumbnails = 9

    private var stripWidth: CGFloat {
        let count = CGFloat(min(session.images.count, Self.visibleThumbnails))
        return count * Self.thumbnail + (count - 1) * Self.spacing
    }

    var body: some View {
        HStack(spacing: 4) {
            arrow("chevron.backward", help: "Previous Image", enabled: viewer.canShowPrevious) {
                viewer.showPrevious()
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: Self.spacing) {
                        ForEach(session.images.indices, id: \.self) { position in
                            thumbnail(position).id(position)
                        }
                    }
                    // Room for the current thumbnail's ring inside the scroll view's clip.
                    .padding(4)
                }
                .scrollIndicators(.never)
                .scrollDisabled(session.images.count <= Self.visibleThumbnails)
                .frame(width: stripWidth + 8, height: Self.thumbnail + 8)
                .padding(-4)
                .onAppear { proxy.scrollTo(viewer.index, anchor: .center) }
                .onChange(of: viewer.index) { _, index in
                    withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
            arrow("chevron.forward", help: "Next Image", enabled: viewer.canShowNext) {
                viewer.showNext()
            }
        }
        .padding(8)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func arrow(_ symbol: String, help: String, enabled: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func thumbnail(_ position: Int) -> some View {
        let isCurrent = position == viewer.index
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button { viewer.show(position) } label: {
            ZStack {
                if let image = TranscriptThumbnails.remembered(for: session.images[position], api: session.api)
                    ?? viewer.items[position]?.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    shape.fill(.quaternary.opacity(0.3))
                }
            }
            .frame(width: Self.thumbnail, height: Self.thumbnail)
            .clipShape(shape)
            .overlay(shape.strokeBorder(hairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(isCurrent ? 1 : 0.7)
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-4)
            }
        }
        .help(session.names[position])
        .accessibilityLabel("Image \(position + 1) of \(session.images.count)"
                            + (session.images[position].filename.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Tracks how far the window's toolbar reaches into the canvas. It stays mounted while no image is
/// open, so the inset is already known when one opens.
private struct ImageViewerToolbarInset: NSViewRepresentable {
    let viewer: ImageViewer

    func makeNSView(context: Context) -> ImageViewerToolbarInsetView {
        let view = ImageViewerToolbarInsetView()
        view.viewer = viewer
        return view
    }

    func updateNSView(_ view: ImageViewerToolbarInsetView, context: Context) {
        view.viewer = viewer
    }
}

final class ImageViewerToolbarInsetView: NSView {
    weak var viewer: ImageViewer?
    private var observation: NSKeyValueObservation?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = window?.observe(\.contentLayoutRect) { [weak self] _, _ in
            Task { @MainActor in self?.measure() }
        }
        measure()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        measure()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        measure()
    }

    private func measure() {
        guard let window else { return }
        let inset = max(0, convert(window.contentLayoutRect, from: nil).minY - bounds.minY)
        guard inset != viewer?.toolbarInset else { return }
        // Layout can run inside a SwiftUI update, so the model changes on the next turn.
        Task { @MainActor [weak self] in self?.viewer?.toolbarInset = inset }
    }
}

/// Trackpad scrolling pans a zoomed image or, with a horizontal two-finger swipe, pages once per
/// gesture. Smart zoom toggles fit. Scrolling over the canvas never reaches the transcript beneath.
private struct ImageViewerEvents: NSViewRepresentable {
    let viewer: ImageViewer
    let capsuleFrame: CGRect

    func makeNSView(context: Context) -> ImageViewerEventView {
        let view = ImageViewerEventView()
        view.viewer = viewer
        view.capsuleFrame = capsuleFrame
        viewer.anchorView = view
        return view
    }

    func updateNSView(_ view: ImageViewerEventView, context: Context) {
        view.viewer = viewer
        view.capsuleFrame = capsuleFrame
        viewer.anchorView = view
    }

    static func dismantleNSView(_ view: ImageViewerEventView, coordinator: ()) {
        view.stop()
    }
}

final class ImageViewerEventView: NSView {
    weak var viewer: ImageViewer?
    var capsuleFrame: CGRect = .zero
    private var monitor: Any?
    private var swipe: CGFloat = 0
    private var hasPaged = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .smartMagnify]) { [weak self] event in
            MainActor.assumeIsolated { self?.consumes(event) == true } ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func consumes(_ event: NSEvent) -> Bool {
        guard let viewer, viewer.session != nil, !viewer.isClosing, event.window === window else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return false }
        if event.type == .scrollWheel && capsuleFrame.contains(point) { return false }
        switch event.type {
        case .smartMagnify:
            viewer.toggleZoom(at: point)
        case .scrollWheel:
            scroll(event, viewer: viewer)
        default:
            return false
        }
        return true
    }

    private func scroll(_ event: NSEvent, viewer: ImageViewer) {
        if viewer.isZoomed {
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            viewer.pan(by: CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
            return
        }
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            swipe = 0
            hasPaged = false
        }
        guard event.phase.contains(.began) || event.phase.contains(.changed) else { return }
        swipe += event.scrollingDeltaX
        guard !hasPaged, abs(swipe) > 60, abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) else { return }
        hasPaged = true
        // Fingers moving left show the next image, whichever way scrolling is set to run.
        let next = event.isDirectionInvertedFromDevice ? swipe < 0 : swipe > 0
        if next { viewer.showNext() } else { viewer.showPrevious() }
    }
}
