import ToyBoxKit
import SwiftUI

extension ChannelAgent.StatusLine {
    package var textColor: Color { cue == .working ? .primary.opacity(0.85) : ChannelInk.secondary }

    package static func waitingCue(in scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 244.0 / 255, green: 190.0 / 255, blue: 102.0 / 255, opacity: 1)
            : Color(.sRGB, red: 154.0 / 255, green: 103.0 / 255, blue: 0, opacity: 1)
    }
}
