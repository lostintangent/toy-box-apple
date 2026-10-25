import AppKit
import ChannelKit

@MainActor
final class TranscriptScrollAnimation: NSObject, NSAnimationDelegate {
    static let duration: TimeInterval = 0.2

    let startIntent: TranscriptScrollModel.Intent
    private(set) var progress: CGFloat = 0
    private let clock: NSAnimation
    private let onFrame: () -> Void

    init(start: TranscriptScrollModel.Intent, framesPerSecond: Int, onFrame: @escaping () -> Void) {
        startIntent = start
        self.onFrame = onFrame
        clock = NSAnimation(duration: Self.duration, animationCurve: .easeInOut)
        super.init()
        clock.animationBlockingMode = .nonblocking
        clock.frameRate = Float(max(60, framesPerSecond))
        let frames = max(1, Int(ceil(Self.duration * Double(clock.frameRate))))
        clock.progressMarks = (1...frames).map { NSNumber(value: Double($0) / Double(frames)) }
        clock.delegate = self
    }

    func start() { clock.start() }

    func stop() {
        clock.delegate = nil
        clock.stop()
    }

    static func shouldAnimate(reducesMotion: Bool, distance: CGFloat) -> Bool {
        !reducesMotion && distance > 0.5
    }

    static func placement(from start: TranscriptScrollModel.Intent, to target: TranscriptScrollModel.Intent,
                          progress: CGFloat, rows: [TranscriptScrollModel.RowFrame],
                          viewport: TranscriptScrollModel.Viewport) -> TranscriptScrollModel.Placement {
        precondition(progress.isFinite && (0...1).contains(progress))
        let first = TranscriptScrollModel.placement(for: start, rows: rows, viewport: viewport)
        let last = TranscriptScrollModel.placement(for: target, rows: rows, viewport: viewport)
        guard let firstOrigin = first.origin, let lastOrigin = last.origin else { return last }
        return .init(intent: last.intent, origin: firstOrigin + (lastOrigin - firstOrigin) * progress,
                     unavailableTarget: last.unavailableTarget)
    }

    nonisolated func animation(_ animation: NSAnimation, didReachProgressMark progress: NSAnimation.Progress) {
        MainActor.assumeIsolated {
            self.progress = CGFloat(clock.currentValue)
            onFrame()
        }
    }

    nonisolated func animationDidEnd(_ animation: NSAnimation) {
        MainActor.assumeIsolated {
            progress = 1
            onFrame()
        }
    }
}
