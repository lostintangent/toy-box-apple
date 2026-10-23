import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private struct ChannelTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var channelTextScale: CGFloat {
        get { self[ChannelTextScaleKey.self] }
        set { self[ChannelTextScaleKey.self] = newValue }
    }
}
