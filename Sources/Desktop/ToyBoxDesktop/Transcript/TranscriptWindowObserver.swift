import AppKit
import ToyBoxClient
import SwiftUI
import ToyBoxUI

@MainActor
final class TranscriptWindowObserver {
    private weak var scrollView: NSScrollView?
    private weak var window: NSWindow?
    private var notifications: [NSObjectProtocol] = []

    func attach(to view: NSView) {
        let scroll = view.enclosingScrollView
        guard scroll !== scrollView || view.window !== window else { return }
        detach()
        scrollView = scroll
        window = view.window
        if let scroll { observeResizes(of: scroll) }
        for name in [NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification] {
            guard let window = view.window else { break }
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.liveResizeChanged?(name == NSWindow.willStartLiveResizeNotification) }
            })
        }
    }

    /// Runs when the user starts dragging a window edge, with `true`, and when they let go.
    var liveResizeChanged: (@MainActor (_ started: Bool) -> Void)?

    var viewportTop: CGFloat? {
        guard let scrollView else { return nil }
        return scrollView.contentView.bounds.minY + scrollView.contentInsets.top
    }

    /// Whether the transcript is following its newest message. A window resize then keeps the end of the
    /// content at the bottom of the viewport in the same layout pass that draws the new size. SwiftUI's
    /// follow lands a frame or more later, which a live resize shows as the newest message drifting.
    var pinsToBottom = false
    private var isResizing = false

    private func observeResizes(of scroll: NSScrollView) {
        let clip = scroll.contentView
        clip.postsFrameChangedNotifications = true
        notifications.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.containerResized() }
        })
        // SwiftUI writes its own offset to the clip after it resizes the content, in the same pass. When the
        // content's estimated height shrank and grew back during a drag, that offset is thousands of points up.
        // The pin's own scroll lands on the end, so the bounds change it causes leaves nothing to move.
        clip.postsBoundsChangedNotifications = true
        notifications.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { if self?.resizes == true { self?.pinToBottom() } }
        })
        guard let document = scroll.documentView else { return }
        document.postsFrameChangedNotifications = true
        notifications.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: document, queue: nil) { [weak self] _ in
            // Rewrapping for a new width resizes the content after the container, in the same pass, and
            // the content grows a pass after SwiftUI reports its new size, so the end follows it here.
            MainActor.assumeIsolated { self?.pinToBottom() }
        })
    }

    /// Whether the window is resizing, so the content's moves are its rewrapping, never the reader's.
    var resizes: Bool { isResizing || window?.inLiveResize == true }

    private func containerResized() {
        pinToBottom()
        guard !isResizing else { return }
        isResizing = true
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated { self?.isResizing = false }
        }
    }

    private var bottomOffset: CGFloat? {
        guard let scrollView, let document = scrollView.documentView, document.isFlipped else { return nil }
        let clip = scrollView.contentView
        let end = document.frame.height + scrollView.contentInsets.bottom - clip.bounds.height
        return max(-scrollView.contentInsets.top, end)
    }

    private func pinToBottom() {
        if pinsToBottom { scrollToEnd() }
    }

    /// Writes the end in one move, where the model reads it. SwiftUI's scroll to the end's view rests
    /// short of it while the rows above are estimates, and lands again on every measure.
    func scrollToEnd() {
        guard let scrollView, let bottom = bottomOffset else { return }
        let clip = scrollView.contentView
        guard abs(clip.bounds.minY - bottom) > 0.25 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: bottom))
        scrollView.reflectScrolledClipView(clip)
    }

    func scroll(by delta: CGFloat) {
        guard let scrollView, let document = scrollView.documentView, delta.isFinite else { return }
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        let target = CGPoint(x: clip.bounds.origin.x,
                             y: min(maximum, max(0, clip.bounds.origin.y + (document.isFlipped ? delta : -delta))))
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }

    func restoreReadingBottom(_ bottom: CGFloat, of frame: TranscriptMessageFrame) -> Bool {
        guard let scrollView, let document = scrollView.documentView,
              document.isFlipped else { return false }
        let clip = scrollView.contentView
        let offset = TranscriptCoordinates.targetOffset(
            for: frame, bottom: bottom, topInset: scrollView.contentInsets.top)
        let minimum = -scrollView.contentInsets.top
        let maximum = max(minimum, document.bounds.height + scrollView.contentInsets.bottom - clip.bounds.height)
        let target = min(maximum, max(minimum, offset))
        guard abs(clip.bounds.minY - target) > 0.25 else { return true }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clip)
        return false
    }

    func announce(_ message: String) {
        guard let window, window.isKeyWindow, window.isVisible, !window.isMiniaturized else { return }
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func detach() {
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        scrollView = nil
        window = nil
        isResizing = false
    }
}

struct TranscriptWindowProbe: NSViewRepresentable {
    let observer: TranscriptWindowObserver
    #if TOY_BOX_BENCHMARK
    var benchmarkGeometry: (@MainActor () -> BenchmarkScrollGeometry?)? = nil
    var benchmarkPlace: (@MainActor () -> BenchmarkPlace?)? = nil
    var benchmarkInteraction: ChannelInteraction? = nil
    #endif

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        configure(view)
        Task { @MainActor [weak view] in
            guard let view else { return }
            observer.attach(to: view)
        }
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.observer?.detach()
    }

    private func configure(_ view: ProbeView) {
        view.observer = observer
        #if TOY_BOX_BENCHMARK
        view.benchmarkGeometry = benchmarkGeometry
        view.benchmarkPlace = benchmarkPlace
        view.benchmarkInteraction = benchmarkInteraction
        #endif
    }

    final class ProbeView: NSView {
        weak var observer: TranscriptWindowObserver?
        #if TOY_BOX_BENCHMARK
        var benchmarkGeometry: (@MainActor () -> BenchmarkScrollGeometry?)?
        var benchmarkPlace: (@MainActor () -> BenchmarkPlace?)?
        weak var benchmarkInteraction: ChannelInteraction?
        #endif

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self else { return }
                observer?.attach(to: self)
            }
        }
    }
}

#if TOY_BOX_BENCHMARK
extension TranscriptWindowProbe.ProbeView: BenchmarkScrollGeometrySource {
    func benchmarkScrollGeometry() -> BenchmarkScrollGeometry? { benchmarkGeometry?() }
    func benchmarkPlaceSnapshot() -> BenchmarkPlace? { benchmarkPlace?() }
}

extension BenchmarkPlace {
    init?(messageFrames: [String: TranscriptMessageFrame], viewport: TranscriptViewport,
          nativeTop: CGFloat?, historyStart: Int?) {
        guard viewport.height.isFinite, viewport.height > 0, let nativeTop, nativeTop.isFinite,
              let historyStart else { return nil }
        var rows: [String: CGRect] = [:]
        for (id, frame) in messageFrames where frame.sequence > 0 && frame.historyStart == historyStart {
            let rect = TranscriptCoordinates.viewportFrame(frame, top: nativeTop).rect
            if rect.minY.isFinite, rect.height.isFinite, rect.height > 0 { rows[id] = rect }
        }
        self.init(rows: rows, viewportHeight: viewport.height)
    }
}

extension BenchmarkScrollGeometry {
    init?(messageFrames: [String: TranscriptMessageFrame], viewport: TranscriptViewport,
          nativeTop: CGFloat?, historyStart: Int?) {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0, let nativeTop, nativeTop.isFinite,
              let historyStart else { return nil }
        var tops: [String: CGFloat] = [:]
        var first: (id: String, top: CGFloat)?
        for (id, frame) in messageFrames where frame.sequence > 0 && frame.historyStart == historyStart {
            let positioned = TranscriptCoordinates.viewportFrame(frame, top: nativeTop).rect
            guard positioned.minY.isFinite, positioned.height.isFinite, positioned.height > 0,
                  positioned.width.isFinite, positioned.width > 0,
                  positioned.maxY > -viewport.height, positioned.minY < viewport.height * 2 else { continue }
            tops[id] = positioned.minY
            guard positioned.maxY > 0, positioned.minY < viewport.height else { continue }
            if let first, first.top < positioned.minY
                || (first.top == positioned.minY && first.id < id) { continue }
            first = (id, positioned.minY)
        }
        guard let first else { return nil }
        self.init(firstVisibleRow: first.id, rowTops: tops)
    }
}
#endif

struct TranscriptMessageFrames: PreferenceKey {
    static let defaultValue: [String: TranscriptMessageFrame] = [:]

    static func reduce(value: inout [String: TranscriptMessageFrame],
                       nextValue: () -> [String: TranscriptMessageFrame]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func transcriptMessageFrame(id: String, sequence: Int, historyStart: Int) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: TranscriptMessageFrames.self, value: [
                    id: .init(sequence: sequence, rect: geometry.frame(in: .named("transcript-viewport")),
                              historyStart: historyStart,
                              contentTop: geometry.frame(in: .named("transcript-content")).minY)
                ])
            }
        }
    }
}
