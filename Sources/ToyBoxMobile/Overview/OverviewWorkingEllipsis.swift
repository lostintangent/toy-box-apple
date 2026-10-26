import os
import SwiftUI
import ToyBoxUI
import UIKit

struct OverviewWorkingEllipsis: UIViewRepresentable {
    let size: CGFloat
    let active: Bool

    func makeUIView(context: Context) -> OverviewEllipsisView { OverviewEllipsisView() }

    func updateUIView(_ view: OverviewEllipsisView, context: Context) {
        view.configure(size: size, scale: context.environment.displayScale,
                       color: UIColor(ChannelInk.secondary),
                       active: active && context.environment.scenePhase == .active
                           && !context.environment.accessibilityReduceMotion)
    }

    static func dismantleUIView(_ view: OverviewEllipsisView, coordinator: Void) { view.stop() }
}

final class OverviewEllipsisView: UIView {
    private struct Metrics: Hashable { let size: CGFloat; let scale: CGFloat }
    private struct Rendering { let image: UIImage; let splits: [CGFloat] }
    private static var renderings: [Metrics: Rendering] = [:]
    private static let log = Logger(subsystem: "dev.toybox.mobile", category: "Overview")
    private let imageView = UIImageView()
    let pulse = ChannelEllipsisPulseMask()
    private var metrics: Metrics?
    private var rendering: Rendering?
    private var active = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        imageView.contentMode = .center
        imageView.layer.mask = pulse.layer
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(size: CGFloat, scale: CGFloat, color: UIColor, active: Bool) {
        let metrics = Metrics(size: size, scale: scale)
        if self.metrics != metrics {
            self.metrics = metrics
            rendering = Self.rendering(metrics)
            imageView.image = rendering?.image
            setNeedsLayout()
        }
        imageView.tintColor = color
        self.active = active
        updateActivity()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        let offset = (bounds.width - (rendering?.image.size.width ?? bounds.width)) / 2
        pulse.layout(in: imageView.bounds, splits: rendering?.splits.map { $0 + offset } ?? [])
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateActivity()
    }

    func stop() {
        active = false
        pulse.stop()
    }

    private func updateActivity() {
        if active, window != nil, rendering != nil { pulse.start() }
        else { pulse.stop() }
    }

    private static func rendering(_ metrics: Metrics) -> Rendering? {
        if let rendering = renderings[metrics] { return rendering }
        guard let symbol = UIImage(systemName: "ellipsis",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: metrics.size, weight: .heavy)) else {
            log.error("The native working ellipsis symbol is unavailable.")
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = metrics.scale
        let image = UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
            symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(at: .zero)
        }
        guard let bitmap = image.cgImage else {
            log.error("The native working ellipsis could not be rasterized.")
            return nil
        }
        let rendering = Rendering(image: image.withRenderingMode(.alwaysTemplate),
                                  splits: ChannelEllipsisPulseMask.splits(in: bitmap, scale: metrics.scale)
                                    .map { $0 / metrics.scale })
        renderings[metrics] = rendering
        return rendering
    }
}
