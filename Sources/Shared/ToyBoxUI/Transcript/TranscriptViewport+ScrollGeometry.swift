import ChannelClient
import SwiftUI

extension TranscriptViewport {
    /// The unobscured viewport between the toolbar and the floating bottom bars. The container
    /// excludes safe-area insets, while the visible rect still includes content beneath glass.
    public init(_ geometry: ScrollGeometry) {
        let top = geometry.contentOffset.y + geometry.contentInsets.top
        self.init(top: top,
                  bottomGap: max(0, geometry.contentSize.height - top - geometry.containerSize.height),
                  width: geometry.containerSize.width, height: geometry.containerSize.height,
                  contentHeight: geometry.contentSize.height)
    }
}
