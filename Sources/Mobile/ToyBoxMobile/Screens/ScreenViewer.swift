import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

/// A screen over the whole app, pinch-zoomable to 8× and live while the app is active. Zoom and pan
/// stay in UIKit, like Photos, and the status sits over them, so a frame never touches the zoom.
struct ScreenViewer: View {
    @ViewState private var connection: ScreenConnection
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(api: ChannelAPI, screenID: String) {
        _connection = ViewState(wrappedValue: ScreenConnection(api: api, screenID: screenID))
    }

    var body: some View {
        NavigationStack {
            Canvas(connection: connection, isActive: scenePhase == .active)
                .overlay {
                    ScreenView.Status(connection: connection)
                        .allowsHitTesting(connection.state.phase != .live)
                }
                .ignoresSafeArea(edges: .bottom)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Screen: \(connection.state.title ?? connection.screenID)")
                .navigationTitle(connection.state.title ?? "Screen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                            .accessibilityLabel("Close Screen")
                    }
                }
        }
    }

    /// Hands each frame to the canvas, and the canvas's settled pixels to the connection.
    private struct Canvas: UIViewRepresentable {
        let connection: ScreenConnection
        let isActive: Bool

        func makeUIView(context: Context) -> ScreenCanvas {
            let canvas = ScreenCanvas()
            canvas.report = { [connection] in connection.viewerSize = $0 }
            return canvas
        }

        func updateUIView(_ canvas: ScreenCanvas, context: Context) {
            canvas.isActive = isActive
            canvas.show(connection.picture)
        }
    }
}

/// A screen's latest frame, fitted and centered at 1×, that pinches to 8×, as images do, and pans like a photo. Only
/// a settled zoom or a new viewer size is reported, and a new frame keeps the zoom and position.
final class ScreenCanvas: UIScrollView, UIScrollViewDelegate {
    /// The full frame at its fitted size, with the changed region over it. It's the view that zooms.
    let pictureView = UIView()
    private let regionView = UIView()
    private var picture = Screen.Picture()
    /// Receives the pixels the viewer shows the screen at, or nil while it can't show any.
    var report: (CGSize?) -> Void = { _ in }
    var isActive = true {
        didSet { if isActive != oldValue { reportSize() } }
    }
    private var viewport = CGSize.zero
    /// The latest pinch's settled scale, so a pinch under way never asks for new frames.
    private(set) var settledScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        maximumZoomScale = 8
        accessibilityIdentifier = "screen-canvas"
        pictureView.layer.cornerCurve = .continuous
        pictureView.layer.masksToBounds = true
        pictureView.addSubview(regionView)
        addSubview(pictureView)
        registerForTraitChanges([UITraitDisplayScale.self]) { (canvas: ScreenCanvas, _) in canvas.reportSize() }
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

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

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
}
