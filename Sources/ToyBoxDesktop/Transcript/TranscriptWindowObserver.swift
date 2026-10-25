import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class TranscriptWindowObserver {
    private(set) var isKeyWindow = false
    private(set) var isAttached = false
    @ObservationIgnored private weak var scrollView: NSScrollView?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []

    func attach(to view: NSView) {
        let scroll = view.enclosingScrollView
        guard scroll !== scrollView || view.window !== window else { return }
        detach()
        scrollView = scroll
        window = view.window
        isAttached = scroll != nil && view.window != nil
        isKeyWindow = view.window?.isKeyWindow == true && view.window?.isVisible == true
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: view.window,
                                                                queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isKeyWindow = self.window?.isKeyWindow == true
                        && self.window?.isVisible == true && self.window?.isMiniaturized == false
                }
            }
            notifications.append(token)
        }
    }

    /// The clip view's offset as AppKit has it, which can run ahead of SwiftUI's geometry after a clamp.
    var scrollOffset: CGFloat? { scrollView?.contentView.bounds.minY }

    var viewportTop: CGFloat? {
        guard let scrollView else { return nil }
        return scrollView.contentView.bounds.minY + scrollView.contentInsets.top
    }

    var viewportWidth: CGFloat? {
        guard let scrollView else { return nil }
        return scrollView.contentView.bounds.width - scrollView.contentInsets.left - scrollView.contentInsets.right
    }

    /// Rejects provisional SwiftUI sizing passes before this scroll view owns their layout.
    func containsLayout(_ viewport: TranscriptViewport) -> Bool {
        guard let scrollView, let window, scrollView.window === window else { return false }
        guard let viewportWidth else { return false }
        return abs(viewportWidth - viewport.width) < 0.5
    }

    /// Compensates measured height changes above a reader, without replacing native reader input.
    func scroll(by delta: CGFloat) {
        guard let scrollView, let document = scrollView.documentView, delta.isFinite else { return }
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        let target = CGPoint(x: clip.bounds.origin.x,
                             y: min(maximum, max(0, clip.bounds.origin.y + (document.isFlipped ? delta : -delta))))
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
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
        isKeyWindow = false
        isAttached = false
    }
}

struct TranscriptWindowProbe: NSViewRepresentable {
    let observer: TranscriptWindowObserver
    var benchmarkGeometry: (@MainActor () -> BenchmarkScrollGeometry?)? = nil

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.observer = observer
        view.benchmarkGeometry = benchmarkGeometry
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.observer = observer
        view.benchmarkGeometry = benchmarkGeometry
        Task { @MainActor [weak view] in
            guard let view else { return }
            observer.attach(to: view)
        }
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.observer?.detach()
    }

    final class ProbeView: NSView, BenchmarkScrollGeometrySource {
        weak var observer: TranscriptWindowObserver?
        var benchmarkGeometry: (@MainActor () -> BenchmarkScrollGeometry?)?

        func benchmarkScrollGeometry() -> BenchmarkScrollGeometry? { benchmarkGeometry?() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self else { return }
                observer?.attach(to: self)
            }
        }
    }
}

extension BenchmarkScrollGeometry {
    init?(messageFrames: [String: TranscriptMessageFrame], viewport: TranscriptViewport,
          nativeTop: CGFloat?, historyStart: Int?) {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0, let nativeTop, nativeTop.isFinite,
              let historyStart else { return nil }
        var tops: [String: CGFloat] = [:]
        var reported: [String: CGFloat] = [:]
        var first: (id: String, top: CGFloat)?
        for (id, frame) in messageFrames where frame.sequence > 0 && frame.historyStart == historyStart {
            let positioned = TranscriptCoordinates.viewportFrame(frame, top: nativeTop).rect
            guard positioned.minY.isFinite, positioned.height.isFinite, positioned.height > 0,
                  positioned.width.isFinite, positioned.width > 0,
                  positioned.maxY > -viewport.height, positioned.minY < viewport.height * 2 else { continue }
            tops[id] = positioned.minY
            if BenchmarkScrollGeometry.traceEnabled { reported[id] = frame.rect.minY }
            guard positioned.maxY > 0, positioned.minY < viewport.height else { continue }
            if let first, first.top < positioned.minY
                || (first.top == positioned.minY && first.id < id) { continue }
            first = (id, positioned.minY)
        }
        guard let first else { return nil }
        self.init(firstVisibleRow: first.id, rowTops: tops, reportedTops: reported)
    }
}

struct TranscriptMessageFrame: Equatable {
    var sequence: Int
    var rect: CGRect
    var historyStart: Int
    /// The top in the content, which only layout changes move. Scrolling moves only `rect`.
    var contentTop: CGFloat = 0
    var windowRect: CGRect = .zero
}

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
                              contentTop: geometry.frame(in: .named("transcript-content")).minY,
                              windowRect: geometry.frame(in: .global))
                ])
            }
        }
    }
}
