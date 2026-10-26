import SwiftUI

private struct ChannelTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var channelTextScale: CGFloat {
        get { self[ChannelTextScaleKey.self] }
        set { self[ChannelTextScaleKey.self] = newValue }
    }
}
