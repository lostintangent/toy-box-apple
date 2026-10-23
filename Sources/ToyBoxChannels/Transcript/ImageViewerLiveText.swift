import AppKit
import SwiftUI
import VisionKit

/// Live Text over the presented image. Text in it can be selected and copied, and codes and links
/// in it opened. VisionKit draws its glass Live Text button at the image's bottom-trailing corner.
struct ImageViewerLiveText: NSViewRepresentable {
    let viewer: ImageViewer
    let analysis: ImageAnalysis?
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
    private var monitor: Any?
    private var menuObserver: (any NSObjectProtocol)?
    private var settle: Task<Void, Never>?

    /// How long the overlay stays hidden after an animated move, so it returns once the image has
    /// settled rather than leading it.
    static let settleDelay: Duration = .milliseconds(350)

    override init(frame: NSRect) {
        super.init(frame: frame)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
        overlay.isHidden = true
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        overlay.setContentsRectNeedsUpdate()
    }

    func present(analysis: ImageAnalysis?, in frame: CGRect, animated: Bool) {
        let moved = frame != imageFrame
        let replaced = analysis !== overlay.analysis
        imageFrame = frame
        if replaced { overlay.analysis = analysis }
        overlay.isHidden = analysis == nil
        if moved { overlay.setContentsRectNeedsUpdate() }
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
        return Target(text: overlay.hasText(at: point),
                      control: overlay.hasInteractiveItem(at: point) || overlay.hasSupplementaryInterface(at: point),
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

    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        Self.contentsRect(of: imageFrame, in: bounds.size)
    }

    /// The image's frame in VisionKit's unit space, which runs past the unit square when zoomed.
    nonisolated static func contentsRect(of frame: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(x: frame.minX / size.width, y: frame.minY / size.height,
                      width: frame.width / size.width, height: frame.height / size.height)
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldHandleKeyDownEvent event: NSEvent) -> Bool {
        false
    }

    /// The text menu keeps Copy, Look Up, Translate and Share, without VisionKit's image items.
    func overlayView(_ overlayView: ImageAnalysisOverlayView, updatedMenuFor menu: NSMenu, for event: NSEvent,
                     at point: CGPoint) -> NSMenu {
        Self.removeImageItems(from: menu)
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
