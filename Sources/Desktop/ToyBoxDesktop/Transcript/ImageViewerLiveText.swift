import AppKit
import SwiftUI
import VisionKit

/// Live Text over the presented image. Text in it can be selected and copied, and codes and links
/// in it opened. VisionKit draws its glass Live Text button at the image's bottom-trailing corner.
struct ImageViewerLiveText: NSViewRepresentable {
    let viewer: ImageViewer
    let analysis: ImageAnalysis?
    var cornerTone: ImageViewerCornerTone?
    /// The presented image's frame in the canvas.
    let imageFrame: CGRect
    /// The button hides while zoomed, when selection still works.
    let showsButton: Bool

    func makeNSView(context: Context) -> ImageViewerLiveTextView {
        let view = ImageViewerLiveTextView()
        view.viewer = viewer
        viewer.liveTextView = view.overlay
        update(view, context: context)
        return view
    }

    func updateNSView(_ view: ImageViewerLiveTextView, context: Context) {
        view.viewer = viewer
        viewer.liveTextView = view.overlay
        update(view, context: context)
    }

    private func update(_ view: ImageViewerLiveTextView, context: Context) {
        let animated = context.transaction.animation != nil && !context.transaction.disablesAnimations
        view.cornerTone = cornerTone
        view.present(analysis: analysis, in: imageFrame, animated: animated)
        if view.overlay.isSupplementaryInterfaceHidden == showsButton {
            view.overlay.setSupplementaryInterfaceHidden(!showsButton, animated: !animated)
        }
    }

    static func dismantleNSView(_ view: ImageViewerLiveTextView, coordinator: ()) {
        view.stop()
    }
}

final class ImageViewerLiveTextView: NSView, ImageAnalysisOverlayViewDelegate {
    weak var viewer: ImageViewer?
    private(set) lazy var overlay = ImageAnalysisOverlayView(self)
    private(set) var imageFrame: CGRect = .zero
    /// The button's glass takes its appearance from the image beneath it rather than the window.
    var cornerTone: ImageViewerCornerTone? {
        didSet { if cornerTone != oldValue { matchAppearance() } }
    }
    private var monitor: Any?
    private var menuObserver: (any NSObjectProtocol)?
    private var settle: Task<Void, Never>?

    /// How long the overlay stays hidden after an animated move, so it returns once the image has
    /// settled rather than leading it.
    static let settleDelay: Duration = .milliseconds(350)

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A zoomed image, and the overlay over it, runs past the canvas.
        clipsToBounds = true
        overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
        overlay.isHidden = true
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        matchAppearance()
    }

    /// A dark window's glass turns gray over a white screenshot and its glyph fades to about 1.9:1,
    /// so the overlay follows the image. This view keeps the window's appearance.
    private func matchAppearance() {
        let name = Self.overlayAppearance(for: cornerTone, in: effectiveAppearance)
        if overlay.appearance?.name != name { overlay.appearance = name.flatMap(NSAppearance.init(named:)) }
    }

    /// Increase Contrast still applies, since the system adds it to either appearance.
    nonisolated static func overlayAppearance(for tone: ImageViewerCornerTone?,
                                              in window: NSAppearance) -> NSAppearance.Name? {
        guard let tone else { return nil }
        // Where the image is transparent, the canvas shows through.
        let canvas: Double = window.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0 : 1
        return tone.isLight(over: canvas) ? .aqua : .darkAqua
    }

    override func layout() {
        super.layout()
        overlay.frame = imageFrame
    }

    func present(analysis: ImageAnalysis?, in frame: CGRect, animated: Bool) {
        let moved = frame != imageFrame
        let replaced = analysis !== overlay.analysis
        imageFrame = frame
        if replaced { overlay.analysis = analysis }
        overlay.isHidden = analysis == nil
        if moved { overlay.frame = frame }
        guard analysis != nil, animated, moved || replaced else { return }
        // The highlights and button can't follow a SwiftUI animation, so they wait it out.
        overlay.alphaValue = 0
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let overlay = self?.overlay else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                overlay.animator().alphaValue = 1
            }
        }
    }

    func stop() {
        settle?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        menuObserver = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnKeyFocus() }
        }
    }

    // MARK: Routing

    /// What VisionKit draws at a point in this view.
    struct Target: Equatable {
        /// Recognized text.
        var text = false
        /// A code, a link or the Live Text button.
        var control = false
        var hasSelection = false
    }

    func target(at point: CGPoint) -> Target {
        guard !overlay.isHidden, overlay.alphaValue > 0, overlay.analysis != nil, bounds.contains(point) else {
            return Target()
        }
        // VisionKit reads points from the overlay's top-left, although the overlay isn't flipped.
        let local = CGPoint(x: point.x - imageFrame.minX, y: point.y - imageFrame.minY)
        return Target(text: overlay.hasText(at: local),
                      control: overlay.hasInteractiveItem(at: local) || overlay.hasSupplementaryInterface(at: local),
                      hasSelection: overlay.hasActiveTextSelection)
    }

    func isOverLiveText(_ point: CGPoint) -> Bool {
        let target = target(at: point)
        return target.text || target.control
    }

    /// VisionKit's view claims every point, so it only receives the clicks and hovers that land on
    /// what it draws. Everything else reaches the viewer's zoom, pan and drag beneath, and a
    /// right-click only reaches it on a selection, for the text menu.
    nonisolated static func routes(_ type: NSEvent.EventType?, to target: Target) -> Bool {
        switch type {
        case .leftMouseDown, .mouseMoved, .cursorUpdate: target.text || target.control
        case .rightMouseDown: target.text && target.hasSelection
        default: false
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard Self.routes(NSApp.currentEvent?.type, to: target(at: local)) else { return nil }
        return super.hitTest(point)
    }

    /// Sees each press before the window dispatches it. SwiftUI's gestures see every press too, even
    /// one VisionKit handles, so the viewer learns which presses are Live Text's.
    private func observe(_ event: NSEvent) {
        guard event.window === window else { return }
        switch event.type {
        case .leftMouseDown:
            let point = convert(event.locationInWindow, from: nil)
            let isOnLiveText = isOverLiveText(point)
            if viewer?.isPressingLiveText != isOnLiveText { viewer?.isPressingLiveText = isOnLiveText }
            // A click elsewhere lets go of the selection, as it would in a document.
            if bounds.contains(point), !isOnLiveText, overlay.hasActiveTextSelection { overlay.resetSelection() }
        case .leftMouseUp:
            // After the release is dispatched, so the stage's gestures still see whose press it was.
            Task { @MainActor [weak self] in
                if self?.viewer?.isPressingLiveText == true { self?.viewer?.isPressingLiveText = false }
                self?.returnKeyFocus()
            }
        default:
            break
        }
    }

    /// VisionKit takes first responder to select. Once the click or menu is done the viewer takes
    /// it back, so the keyboard keeps paging, closing and copying, and the selection stays.
    private func returnKeyFocus() {
        guard let responder = window?.firstResponder as? NSView, responder.isDescendant(of: overlay) else { return }
        viewer?.reclaimKeyFocus()
    }

    // MARK: Keys VisionKit passes on

    override func keyDown(with event: NSEvent) {
        guard let viewer else { return super.keyDown(with: event) }
        switch event.specialKey {
        case .leftArrow: viewer.showPrevious()
        case .rightArrow: viewer.showNext()
        default:
            if event.keyCode == 53 { viewer.escape() } else if event.charactersIgnoringModifiers == " " {
                viewer.close()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func cancelOperation(_ sender: Any?) { viewer?.escape() }

    // MARK: ImageAnalysisOverlayViewDelegate

    /// The overlay covers exactly the image, so its contents fill it. VisionKit hit-tests any other
    /// contents rect correctly but draws the selection off by the image's size times how far the
    /// rect's center sits from the overlay's. For a fitted image below the toolbar, that's a line above
    /// its text.
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldHandleKeyDownEvent event: NSEvent) -> Bool {
        false
    }

    /// The text menu keeps Copy, Look Up, Translate and Share, without VisionKit's image items.
    func overlayView(_ overlayView: ImageAnalysisOverlayView, updatedMenuFor menu: NSMenu, for event: NSEvent,
                     at point: CGPoint) -> NSMenu {
        Self.removeImageItems(from: menu)
        menu.appearance = effectiveAppearance
        return menu
    }

    static let imageMenuTags: Set<Int> = [
        ImageAnalysisOverlayView.MenuTag.copyImage, ImageAnalysisOverlayView.MenuTag.shareImage,
        ImageAnalysisOverlayView.MenuTag.copySubject, ImageAnalysisOverlayView.MenuTag.shareSubject,
        ImageAnalysisOverlayView.MenuTag.lookupItem,
    ]

    static func removeImageItems(from menu: NSMenu) {
        for item in menu.items where imageMenuTags.contains(item.tag) { menu.removeItem(item) }
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}

/// How light an image is in its bottom-trailing 64-point square, where VisionKit draws the Live Text
/// button. Measured once per decoded image.
struct ImageViewerCornerTone: Equatable, Sendable {
    /// The average relative luminance of the square's opaque content.
    var luminance: Double
    /// How much of the square is opaque, from 0 to 1.
    var coverage: Double

    static let side: CGFloat = 64

    init(luminance: Double, coverage: Double) {
        self.luminance = luminance
        self.coverage = coverage
    }

    nonisolated init?(_ image: CGImage, pixelsPerPoint: CGFloat) {
        let side = Int((Self.side * max(1, pixelsPerPoint)).rounded())
        let width = min(image.width, side), height = min(image.height, side)
        // CGImage crops from the top-left, so the bottom-trailing square starts here.
        guard width > 0, height > 0,
              let corner = image.cropping(to: CGRect(x: image.width - width, y: image.height - height,
                                                     width: width, height: height)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let samples = 16
        var pixels = [UInt8](repeating: 0, count: samples * samples * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: samples, height: samples,
                                          bitsPerComponent: 8, bytesPerRow: samples * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(corner, in: CGRect(x: 0, y: 0, width: samples, height: samples))
            return true
        }
        guard drawn else { return nil }
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        var lightness = 0.0, opacity = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0 else { continue }
            let red = linear(Double(pixels[offset]) / 255 / alpha)
            let green = linear(Double(pixels[offset + 1]) / 255 / alpha)
            let blue = linear(Double(pixels[offset + 2]) / 255 / alpha)
            lightness += (0.2126 * red + 0.7152 * green + 0.0722 * blue) * alpha
            opacity += alpha
        }
        let count = Double(samples * samples)
        self.init(luminance: opacity > 0 ? lightness / opacity : 0, coverage: opacity / count)
    }

    /// Whether the square reads as light, with `background` showing through where it's transparent.
    func isLight(over background: Double) -> Bool {
        luminance * coverage + background * (1 - coverage) > 0.5
    }
}
