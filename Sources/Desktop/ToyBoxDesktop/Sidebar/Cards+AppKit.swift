import AppKit
import ChannelClient
import SwiftUI
import ToyBoxUI

// The sidebar's cards: a waiting row's answers from its popover, and Talk to Lead's recorder.

extension NeedsYouCards {
    /// The sidebar's answers, with drafts, VoiceOver announcements and the spec's motion.
    convenience init(checks: CardChecks) {
        self.init(checks: checks, draft: { .shared(serverURL: $0.api.baseURL, channelID: $0.id) },
                  announce: CardMotion.announce, animate: { withAnimation($0.animation, $1) })
    }
}

extension TalkRecorder {
    /// The sidebar's recorder, with live dictation, VoiceOver announcements and the spec's motion.
    convenience init(checks: CardChecks) {
        self.init(system: .live, checks: checks, draft: { .shared(serverURL: $0.api.baseURL, channelID: $0.id) },
                  announce: CardMotion.announce, animate: { withAnimation($0.animation, $1) })
    }
}

extension CardChecks {
    /// The sidebar's done checks, settling with the spec's motion.
    convenience init() {
        self.init(animate: { withAnimation($0.animation, $1) })
    }
}

extension CardMotion {
    /// The beat's motion from the spec, or a short ease without bounce under Reduce Motion.
    @MainActor var animation: Animation {
        animation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    @MainActor static func announce(_ announcement: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: announcement,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
