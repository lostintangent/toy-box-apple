import CryptoKit
import UIKit
import VisionKit

@MainActor
final class ArtifactImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private(set) var file: URL?
    var onError: ((String) -> Void)?
    var onFitChanged: ((Bool) -> Void)?
    private(set) var fitPublication: Task<Void, Never>?
    private var publishedFit: Bool?
    private let analysisInteraction = ImageAnalysisInteraction()
    private var analysisTask: Task<Void, Never>?
    private var viewportSize = CGSize.zero
    private var logicalSize = CGSize.zero
    private static let analyses: NSCache<NSString, ImageAnalysis> = {
        let cache = NSCache<NSString, ImageAnalysis>()
        cache.countLimit = 8
        return cache
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        analysisInteraction.preferredInteractionTypes = [.textSelection, .dataDetectors]
        imageView.addInteraction(analysisInteraction)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { nil }

    deinit { analysisTask?.cancel(); fitPublication?.cancel() }

    var isAtFitScale: Bool {
        abs(zoomScale - minimumZoomScale) <= max(minimumZoomScale * 0.001, CGFloat.ulpOfOne * 8)
    }

    static func fitScale(image: CGSize, viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, image.width.isFinite, image.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(1, viewport.width / image.width, viewport.height / image.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if viewportSize != bounds.size {
            let wasFitted = isAtFitScale
            viewportSize = bounds.size
            updateZoomLimits()
            if wasFitted { fit() }
        }
        centerImage()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopAnalysis() }
        else { analyze() }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let location = gestureRecognizer.location(in: imageView)
            if analysisInteraction.hasInteractiveItem(at: location) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func configure(image: UIImage, size: CGSize, file: URL, title: String) {
        imageView.accessibilityLabel = title
        guard self.file != file else { return }
        stopAnalysis()
        publishedFit = nil
        self.file = file
        logicalSize = size
        setZoomScale(1, animated: false)
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        updateZoomLimits()
        fit()
        analyze()
    }

    func fit() { setZoomScale(minimumZoomScale, animated: false); centerImage(); publishFit() }
    func actualSize() { setZoomScale(1, animated: false); centerImage(); publishFit() }

    func stop() {
        stopAnalysis()
        fitPublication?.cancel()
        fitPublication = nil
        file = nil
        imageView.image = nil
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage(); publishFit() }

    private func publishFit() {
        let fitted = isAtFitScale
        guard publishedFit != fitted else { return }
        publishedFit = fitted
        fitPublication?.cancel()
        let file = file
        // Configuration can run inside a SwiftUI update, so publish outside that update.
        fitPublication = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.file == file else { return }
            onFitChanged?(fitted)
        }
    }

    private func updateZoomLimits() {
        minimumZoomScale = Self.fitScale(image: logicalSize, viewport: bounds.size)
        maximumZoomScale = max(1, minimumZoomScale * 8)
    }

    private func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }

    private func stopAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisInteraction.analysis = nil
    }

    private func analyze() {
        guard ImageAnalyzer.isSupported, window != nil, analysisTask == nil,
              analysisInteraction.analysis == nil, let image = imageView.image, let file else { return }
        analysisTask = Task { [weak self] in
            do {
                let digest = try await Task.detached(priority: .utility) {
                    let data = try Data(contentsOf: file, options: .mappedIfSafe)
                    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }.value
                try Task.checkCancellation()
                let analysis: ImageAnalysis
                if let cached = Self.analyses.object(forKey: digest as NSString) { analysis = cached }
                else {
                    analysis = try await ImageAnalyzer().analyze(image, configuration: .init([.text, .machineReadableCode]))
                    try Task.checkCancellation()
                    Self.analyses.setObject(analysis, forKey: digest as NSString)
                }
                guard let self, self.file == file, window != nil else { return }
                analysisInteraction.analysis = analysis
                analysisTask = nil
            } catch is CancellationError {
            } catch {
                guard let self, self.file == file, !Task.isCancelled else { return }
                analysisTask = nil
                onError?("Live Text is unavailable for this image. \(error.localizedDescription)")
            }
        }
    }
}
