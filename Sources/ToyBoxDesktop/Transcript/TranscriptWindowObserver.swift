import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class TranscriptWindowObserver {
    private(set) var isKeyWindow = false
    @ObservationIgnored private weak var scrollView: NSScrollView?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []

    func attach(to view: NSView) {
        let scroll = view.enclosingScrollView
        guard scroll !== scrollView || view.window !== window else { return }
        detach()
        scrollView = scroll
        window = view.window
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
        if let scroll { observeResizes(of: scroll) }
    }

    /// The clip view's offset as AppKit has it, which can run ahead of SwiftUI's geometry after a clamp.
    var scrollOffset: CGFloat? { scrollView?.contentView.bounds.minY }

    /// Whether the transcript is following its newest message. A window resize then keeps the end of the
    /// content at the bottom of the viewport in the same layout pass that draws the new size. SwiftUI's
    /// follow lands a frame or more later, which a live resize shows as the newest message drifting.
    @ObservationIgnored var pinsToBottom = false
    @ObservationIgnored private var isResizing = false

    private func observeResizes(of scroll: NSScrollView) {
        let clip = scroll.contentView
        clip.postsFrameChangedNotifications = true
        notifications.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.containerResized() }
        })
        guard let document = scroll.documentView else { return }
        document.postsFrameChangedNotifications = true
        notifications.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: document, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                // Rewrapping for a new width resizes the content after the container, in the same pass.
                guard let self, self.isResizing || self.window?.inLiveResize == true else { return }
                self.pinToBottom()
            }
        })
    }

    private func containerResized() {
        pinToBottom()
        guard !isResizing else { return }
        isResizing = true
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated { self?.isResizing = false }
        }
    }

    /// Whether a resize has already pinned the transcript to its end during this layout pass, so a
    /// SwiftUI follow would only move it. SwiftUI rests its own follow a point short of the end.
    var holdsResizePin: Bool {
        guard pinsToBottom, isResizing || window?.inLiveResize == true,
              let bottom = bottomOffset, let clip = scrollView?.contentView else { return false }
        return abs(clip.bounds.minY - bottom) <= 0.25
    }

    private var bottomOffset: CGFloat? {
        guard let scrollView, let document = scrollView.documentView, document.isFlipped else { return nil }
        let clip = scrollView.contentView
        let end = document.frame.height + scrollView.contentInsets.bottom - clip.bounds.height
        return max(-scrollView.contentInsets.top, end)
    }

    private func pinToBottom() {
        guard pinsToBottom, let scrollView, let bottom = bottomOffset else { return }
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
        isResizing = false
    }
}

struct TranscriptWindowProbe: NSViewRepresentable {
    let observer: TranscriptWindowObserver

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.observer = observer
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.observer = observer
        Task { @MainActor [weak view] in
            guard let view else { return }
            observer.attach(to: view)
        }
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.observer?.detach()
    }

    final class ProbeView: NSView {
        weak var observer: TranscriptWindowObserver?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self else { return }
                observer?.attach(to: self)
            }
        }
    }
}

struct TranscriptMessageFrame: Equatable {
    var sequence: Int
    var rect: CGRect
    var historyStart: Int
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
                              historyStart: historyStart)
                ])
            }
        }
    }
}
