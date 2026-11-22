import ToyBoxClient
import SwiftUI

extension TranscriptScroll.Metrics {
    /// The container size excludes the content insets, but the model's viewport spans them.
    public init(_ geometry: ScrollGeometry) {
        let top = max(0, geometry.contentInsets.top), bottom = max(0, geometry.contentInsets.bottom)
        self.init(viewport: .init(width: geometry.containerSize.width,
                                  height: geometry.containerSize.height + top + bottom,
                                  topInset: top, bottomInset: bottom),
                  origin: geometry.contentOffset.y, documentEnd: geometry.contentSize.height)
    }
}
