import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

/// A screen over the whole app, pinch-zoomable to 8× and live while the app is active. Zoom and pan
/// stay in UIKit, like Photos, and the status sits over them, so a frame never touches the zoom. The
/// bar never minimizes, since a pan would then resize the canvas and fit the screen again. In control,
/// one finger drives the host and the Keyboard button types on it.
struct ScreenViewer: View {
    @ViewState private var connection: ScreenConnection
    /// Counts taps on Keyboard, which shows or hides the keyboard.
    @ViewState private var keyboardTaps = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(api: ChannelAPI, screenID: String) {
        _connection = ViewState(wrappedValue: ScreenConnection(api: api, screenID: screenID))
    }

    var body: some View {
        NavigationStack {
            Canvas(connection: connection, isActive: scenePhase == .active, keyboardTaps: keyboardTaps)
                .overlay {
                    ScreenView.Status(connection: connection)
                        .allowsHitTesting(connection.state.phase != .live)
                }
                .ignoresSafeArea(edges: .bottom)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Screen: \(connection.state.title ?? connection.screenID)")
                .navigationTitle(connection.state.title ?? "Screen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarMinimizationBehavior(.never, for: .navigationBar)
                .toolbar {
                    // Each in its own glass, so Keyboard arriving leaves the toggle and Close in place.
                    if connection.state.hasControl {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Keyboard", systemImage: "keyboard") { keyboardTaps += 1 }
                        }
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                    ToolbarItem(placement: .topBarTrailing) { ScreenView.ControlToggle(connection: connection) }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                            .accessibilityLabel("Close Screen")
                    }
                }
        }
    }

    /// Hands each frame to the canvas, and the canvas's settled pixels and input to the connection.
    private struct Canvas: UIViewRepresentable {
        let connection: ScreenConnection
        let isActive: Bool
        let keyboardTaps: Int

        func makeCoordinator() -> Coordinator { Coordinator(keyboardTaps: keyboardTaps) }

        func makeUIView(context: Context) -> ScreenCanvas {
            let canvas = ScreenCanvas()
            canvas.report = { [connection] in connection.viewerSize = $0 }
            canvas.send = { [connection] in connection.send($0) }
            return canvas
        }

        func updateUIView(_ canvas: ScreenCanvas, context: Context) {
            canvas.isActive = isActive
            canvas.show(connection.picture)
            canvas.hasControl = connection.state.hasControl
            if context.coordinator.keyboardTaps != keyboardTaps {
                context.coordinator.keyboardTaps = keyboardTaps
                canvas.toggleKeyboard()
            }
        }

        final class Coordinator {
            var keyboardTaps: Int
            init(keyboardTaps: Int) { self.keyboardTaps = keyboardTaps }
        }
    }
}

/// A screen's latest frame, fitted and centered at 1×, that pinches to 8× and pans like a photo. A pinch stops at
/// 1× and 8× rather than springing back, so the screen stays where it's left. Only a settled zoom or a new viewer
/// size is reported, and a new frame keeps the zoom and position. In control, an accent ring follows the picture's
/// edge, one finger drives the host while two pinch and pan, and keys go to the host.
final class ScreenCanvas: UIScrollView, UIScrollViewDelegate {
    /// The full frame at its fitted size, with the changed region over it. It's the view that zooms.
    let pictureView = UIView()
    private let regionView = UIView()
    /// Over the picture's edge rather than on it, so it stays 2 points at any zoom.
    let ringView = UIView()
    private var picture = Screen.Picture()
    /// Receives the pixels the viewer shows the screen at, or nil while it can't show any.
    var report: (CGSize?) -> Void = { _ in }
    /// Receives the input for the host while the viewer controls it.
    var send: ([Screen.Input]) -> Void = { _ in }
    var isActive = true {
        didSet { if isActive != oldValue { reportSize() } }
    }
    var hasControl = false {
        didSet { if hasControl != oldValue { controlChanged() } }
    }
    private let touches = Touches()
    let typing = ScreenTyping()
    private var pointer = ScreenPointer()
    private var keyboard = ScreenKeyboard()
    /// Presses a still, waiting touch once it has held long enough.
    private var hold: Task<Void, Never>?
    private var viewport = CGSize.zero
    /// The latest pinch's settled scale, so a pinch under way never asks for new frames.
    private(set) var settledScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = false
        maximumZoomScale = 8
        accessibilityIdentifier = "screen-canvas"
        pictureView.layer.cornerCurve = .continuous
        pictureView.layer.masksToBounds = true
        pictureView.addSubview(regionView)
        addSubview(pictureView)
        ringView.isUserInteractionEnabled = false
        ringView.isHidden = true
        ringView.layer.borderWidth = 2
        ringView.layer.cornerCurve = .continuous
        addSubview(ringView)
        touches.isEnabled = false
        touches.handle = { [weak self] touch, phase in self?.handle(touch, phase) }
        addGestureRecognizer(touches)
        typing.keys = { [weak self] presses, down in self?.handle(presses, down: down) ?? false }
        typing.typed = { [weak self] text in self.map { $0.send($0.keyboard.type(text)) } }
        typing.deleted = { [weak self] in self.map { $0.send($0.keyboard.deleteBackward()) } }
        addSubview(typing)
        registerForTraitChanges([UITraitDisplayScale.self]) { (canvas: ScreenCanvas, _) in canvas.reportSize() }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (canvas: ScreenCanvas, _) in canvas.tintColorDidChange() }
        tintColorDidChange()
    }

    required init?(coder: NSCoder) { nil }

    func show(_ picture: Screen.Picture) {
        self.picture = picture
        pictureView.layer.contents = picture.image
        regionView.layer.contents = picture.region?.image
        regionView.isHidden = picture.region == nil
        fit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard viewport != bounds.size else { return }
        viewport = bounds.size
        // A rotated viewer fits the screen again.
        setZoomScale(1, animated: false)
        settledScale = 1
        fit()
        center()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        reportSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportSize()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        pictureView.bounds.isEmpty ? nil : pictureView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        placeRing()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        settledScale = scale
        reportSize()
    }

    /// Sizes the picture to fit the viewer at 1×. A frame of the same shape, such as a sharper one
    /// after a pinch, keeps the zoom and position, and a lost picture keeps its place for the next.
    private func fit() {
        let size = picture.size
        guard size.width > 0, size.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        let scale = min(viewport.width / size.width, viewport.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        if pictureView.bounds.size != fitted {
            let isFirst = pictureView.bounds.isEmpty
            pictureView.bounds.size = fitted
            contentSize = CGSize(width: fitted.width * zoomScale, height: fitted.height * zoomScale)
            pictureView.center = CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
            center()
            if isFirst { contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top) }
        }
        pictureView.layer.cornerRadius = picture.radius * scale
        if let region = picture.region?.bounds {
            regionView.frame = CGRect(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale,
                                      width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
        }
        placeRing()
    }

    /// Lays the ring over the picture as it's zoomed, inside its edge and around its corners.
    private func placeRing() {
        ringView.isHidden = !hasControl || pictureView.bounds.isEmpty
        ringView.frame = pictureView.frame
        ringView.layer.cornerRadius = pictureView.layer.cornerRadius * zoomScale
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        ringView.layer.borderColor = tintColor.resolvedColor(with: traitCollection).cgColor
    }

    /// Centers a picture smaller than the viewer, as the image viewer does.
    private func center() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }

    private func reportSize() {
        let scale = traitCollection.displayScale * settledScale
        let pixels = CGSize(width: viewport.width * scale, height: viewport.height * scale)
        report(isActive && window != nil && pixels.width >= 1 && pixels.height >= 1 ? pixels : nil)
    }

    // Control

    override var canBecomeFirstResponder: Bool { hasControl }

    /// Starts each take afresh with nothing pressed. One finger drives the host, so panning takes two.
    private func controlChanged() {
        (pointer, keyboard) = (ScreenPointer(), ScreenKeyboard())
        hold?.cancel()
        touches.isEnabled = hasControl
        panGestureRecognizer.minimumNumberOfTouches = hasControl ? 2 : 1
        placeRing()
        // A hardware keyboard's keys reach the canvas, and the software keyboard waits for Keyboard.
        if hasControl { becomeFirstResponder() } else if typing.isFirstResponder || isFirstResponder {
            typing.resignFirstResponder()
            resignFirstResponder()
        }
    }

    /// Shows the keyboard for typing on the host, or hides it again.
    func toggleKeyboard() {
        guard hasControl else { return }
        if typing.isFirstResponder { becomeFirstResponder() } else { typing.becomeFirstResponder() }
    }

    /// A pinch or two-finger pan begins unless one finger is already pressing the host.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if hasControl, recognizer === pinchGestureRecognizer || recognizer === panGestureRecognizer,
           pointer.phase == .pressing { return false }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    private func handle(_ touch: UITouch, _ phase: UITouch.Phase) {
        let id = ObjectIdentifier(touch)
        let point = touch.location(in: nil)
        let position = picture.position(of: touch.location(in: pictureView), fittedIn: pictureView.bounds)
        switch phase {
        case .began: drive(pointer.touchBegan(id, at: point, position: position, time: .now))
        case .moved: drive(pointer.touchMoved(id, at: point, position: position))
        case .ended: drive(pointer.touchEnded(id, position: position))
        default: drive(pointer.touchCancelled(id))
        }
    }

    /// Sends what a touch did, then waits for a waiting touch's hold.
    private func drive(_ input: [Screen.Input]) {
        send(input)
        hold?.cancel()
        guard let deadline = pointer.deadline else { return }
        hold = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.drive(self.pointer.holdElapsed(at: .now))
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    /// Sends a hardware keyboard's keys by code, and reports whether the host can press them.
    private func handle(_ presses: Set<UIPress>, down: Bool) -> Bool {
        let codes = presses.compactMap { $0.key.flatMap { Screen.Input.keyCode(hidUsage: $0.keyCode.rawValue) } }
        guard hasControl, !codes.isEmpty else { return false }
        send(codes.flatMap { down ? keyboard.press($0) : keyboard.release($0) })
        return true
    }

    /// Hands each touch on the canvas to the pointer while the viewer has control. It never recognizes, so the
    /// scroll view's pinch and two-finger pan run alongside it.
    private final class Touches: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var handle: (UITouch, UITouch.Phase) -> Void = { _, _ in }
        private var down = Set<ObjectIdentifier>()

        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches {
                down.insert(ObjectIdentifier(touch))
                handle(touch, .began)
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches { handle(touch, .moved) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, .ended) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, .cancelled) }

        override func reset() {
            super.reset()
            down.removeAll()
        }

        /// Once every finger lifts, it fails so the next touch starts a new sequence.
        private func lift(_ touches: Set<UITouch>, _ phase: UITouch.Phase) {
            for touch in touches {
                down.remove(ObjectIdentifier(touch))
                handle(touch, phase)
            }
            if down.isEmpty { state = .failed }
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// The keyboard the Keyboard button shows. What it types goes out as text, and Delete and Return as keys, without
/// corrections. A hardware keyboard's keys go out by code instead.
final class ScreenTyping: UIView, UIKeyInput {
    var typed: (String) -> Void = { _ in }
    var deleted: () -> Void = {}
    /// Sends a hardware keyboard's presses, and reports whether the host can press them.
    var keys: (Set<UIPress>, Bool) -> Bool = { _, _ in false }

    var autocapitalizationType = UITextAutocapitalizationType.none
    var autocorrectionType = UITextAutocorrectionType.no
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    var inlinePredictionType = UITextInlinePredictionType.no

    override var canBecomeFirstResponder: Bool { true }
    /// Always, so Delete reaches the host even though nothing is typed here.
    var hasText: Bool { true }

    func insertText(_ text: String) { typed(text) }
    func deleteBackward() { deleted() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keys(presses, true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keys(presses, false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keys(presses, false) { super.pressesCancelled(presses, with: event) }
    }
}
