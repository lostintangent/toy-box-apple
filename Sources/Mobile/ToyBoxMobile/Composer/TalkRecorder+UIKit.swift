import ChannelClient
import SwiftUI
import UIKit

extension TalkRecorder {
    /// The phone's recorder, with live dictation, VoiceOver announcements and the spec's springs.
    convenience init(checks: CardChecks) {
        self.init(system: .live, checks: checks,
                  draft: { .shared(serverURL: $0.api.baseURL, channelID: $0.id, imageIsReadable: ComposerSession.imageIsReadable) },
                  announce: { UIAccessibility.post(notification: .announcement, argument: $0) },
                  animate: { withAnimation($0.animation, $1) })
    }
}
