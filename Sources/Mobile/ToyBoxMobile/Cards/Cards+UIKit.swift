import ChannelClient
import SwiftUI
import ToyBoxUI
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

extension CardMotion {
    /// The beat's spring from the spec, or a short ease without bounce under Reduce Motion.
    @MainActor var animation: Animation { animation(reduceMotion: UIAccessibility.isReduceMotionEnabled) }
}

extension CardChecks {
    /// The list's done checks, settling with the spec's springs.
    convenience init() {
        self.init(animate: { withAnimation($0.animation, $1) })
    }
}

/// UIKit's list reads each row's separators only when it lays out, and nothing lays it out as the
/// talk card starts shrinking, so a changed `listRowSeparator` waits for some unrelated update. This
/// lays the row's list out again whenever its line changes.
struct TalkRowLine: UIViewRepresentable {
    let isHidden: Bool

    final class Coordinator {
        var isHidden: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        defer { context.coordinator.isHidden = isHidden }
        guard let wasHidden = context.coordinator.isHidden, wasHidden != isHidden else { return }
        // After this update, so the list has the row's new separator when it asks.
        Task { @MainActor [weak view] in
            var ancestor = view?.superview
            while let candidate = ancestor, !(candidate is UICollectionView) { ancestor = candidate.superview }
            (ancestor as? UICollectionView)?.collectionViewLayout.invalidateLayout()
        }
    }
}
