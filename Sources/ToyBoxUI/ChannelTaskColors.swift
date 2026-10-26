import SwiftUI

public enum ChannelTaskColors {
    public static func changes(in scheme: ColorScheme) -> (added: Color, removed: Color) {
        if scheme == .dark {
            (Color(.sRGB, red: 112.0 / 255, green: 213.0 / 255, blue: 138.0 / 255),
             Color(.sRGB, red: 1, green: 139.0 / 255, blue: 139.0 / 255))
        } else {
            (Color(.sRGB, red: 25.0 / 255, green: 108.0 / 255, blue: 46.0 / 255),
             Color(.sRGB, red: 180.0 / 255, green: 35.0 / 255, blue: 36.0 / 255))
        }
    }
}
