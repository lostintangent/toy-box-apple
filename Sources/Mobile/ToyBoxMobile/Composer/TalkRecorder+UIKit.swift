import ChannelClient
import SwiftUI
import UIKit

extension TalkRecorder {
    /// The phone's recorder, with live dictation, VoiceOver announcements and the spec's springs.
    convenience init() {
        self.init(system: .live,
                  draft: { .shared(serverURL: $0.api.baseURL, channelID: $0.id, imageIsReadable: ComposerSession.imageIsReadable) },
                  announce: { UIAccessibility.post(notification: .announcement, argument: $0) },
                  animate: { withAnimation(Self.motion($0), $1) })
    }

    /// The spec's springs, or short eases without bounce under Reduce Motion.
    static func motion(_ motion: CardMotion) -> Animation {
        if UIAccessibility.isReduceMotionEnabled { return .easeInOut(duration: 0.2) }
        return switch motion {
        case .open: .spring(duration: 0.4, bounce: 0.12)
        case .sent: .smooth(duration: 0.35)
        case .settle: .easeOut(duration: 0.4)
        }
    }
}
