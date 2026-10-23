import AppKit
import SwiftUI

struct WindowObserver: NSViewRepresentable {
    var onAttach: (NSWindow) -> Void
    /// Reports whether the window is key, its size, and whether a live resize is still under way.
    var onChange: (_ isKey: Bool, _ size: CGSize, _ isLiveResizing: Bool) -> Void
    /// Reports the sidebar's width, zero when it's hidden, and the inspector's width while it's
    /// fully open. Either is nil when that split view didn't change.
    var onColumns: (CGFloat?, CGFloat?) -> Void = { _, _ in }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onAttach = onAttach
        view.onChange = onChange
        view.onColumns = onColumns
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
        view.onColumns = onColumns
    }

    static let minimumSize = CGSize(width: 760, height: 560)

    @MainActor
    final class ObserverView: NSView {
        var onChange: ((Bool, CGSize, Bool) -> Void)?
        var onColumns: ((CGFloat?, CGFloat?) -> Void)?
        var onAttach: ((NSWindow) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private let splits = NSHashTable<NSSplitView>.weakObjects()
        private var isColumnReportPending = false
        private var settledColumnReport: Task<Void, Never>?
        private var widthFloor: NSLayoutConstraint?
        private var heightFloor: NSLayoutConstraint?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens.removeAll()
            NSLayoutConstraint.deactivate([widthFloor, heightFloor].compactMap { $0 })
            guard let window else { return }
            // SwiftUI replaces `NSWindow.minSize` with the split view's minimum whenever the layout
            // changes, so the window's floor is a constraint on its content view instead.
            if let content = window.contentView {
                // The style mask decides the titlebar. The views can still be unsized here.
                let titlebar = max(0, window.frame.height - window.contentRect(forFrameRect: window.frame).height)
                widthFloor = content.widthAnchor.constraint(greaterThanOrEqualToConstant: WindowObserver.minimumSize.width)
                heightFloor = content.heightAnchor.constraint(
                    greaterThanOrEqualToConstant: WindowObserver.minimumSize.height - titlebar)
                NSLayoutConstraint.activate([widthFloor, heightFloor].compactMap { $0 })
            }
            onAttach?(window)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didResizeNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didEndLiveResizeNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] note in
                    let ended = note.name == NSWindow.didEndLiveResizeNotification
                    MainActor.assumeIsolated { self?.report(endingLiveResize: ended) }
                })
            }
            tokens.append(NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) { [weak self] note in
                // Posted on the main queue, where the split view lives.
                nonisolated(unsafe) let object = note.object
                MainActor.assumeIsolated {
                    guard let self, let split = object as? NSSplitView, split.window === self.window else { return }
                    self.columnsDidResize(in: split)
                }
            })
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report(endingLiveResize: Bool = false) {
            guard let window else { return }
            onChange?(window.isKeyWindow && !window.isMiniaturized, window.frame.size,
                      window.inLiveResize && !endingLiveResize)
        }

        /// Split views resize during layout, so the columns report once layout finishes. Changing
        /// SwiftUI state inside the layout pass can start a constraint update loop.
        private func columnsDidResize(in split: NSSplitView) {
            splits.add(split)
            guard !isColumnReportPending else { return }
            isColumnReportPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isColumnReportPending = false
                reportColumns()
                // A narrower inspector only counts once the layout is still, and SwiftUI brings a
                // collapsed inspector back at its ideal width. Reporting again after a pause
                // catches both.
                settledColumnReport?.cancel()
                settledColumnReport = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    self?.reportColumns()
                }
            }
        }

        /// Reads the columns from the split view items SwiftUI creates for the sidebar and the
        /// inspector. An inspector that's collapsing or opening passes through narrower widths, so
        /// only a fully open inspector reports.
        private func reportColumns() {
            let items = splits.allObjects.filter { $0.window === window }
                .compactMap { ($0.delegate as? NSSplitViewController)?.splitViewItems }.joined()
            var sidebar: CGFloat?
            var inspector: CGFloat?
            for item in items {
                let width = item.viewController.view.frame.width
                switch item.behavior {
                case .sidebar:
                    sidebar = item.isCollapsed ? 0 : width
                case .inspector where !item.isCollapsed && width >= item.minimumThickness
                    && (item.maximumThickness <= 0 || width <= item.maximumThickness):
                    inspector = width
                default:
                    break
                }
            }
            if sidebar != nil || inspector != nil { onColumns?(sidebar, inspector) }
        }

        isolated deinit {
            settledColumnReport?.cancel()
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }
    }
}
