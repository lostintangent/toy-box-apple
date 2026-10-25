import AppKit
import OSLog

@MainActor
final class TranscriptEdgeTrace {
    static let mode = ProcessInfo.processInfo.environment["TOY_BOX_TRANSCRIPT_EDGE_TRACE"]
    private let logger = Logger(subsystem: "dev.toybox.desktop", category: "TranscriptEdges")
    private weak var controller: TranscriptTableEdges?
    private weak var view: NSView?
    private weak var scroll: NSScrollView?
    private var notifications: [NSObjectProtocol] = []
    private var lastOrigins: [ObjectIdentifier: CGPoint] = [:]

    init(controller: TranscriptTableEdges, scroll: NSScrollView) {
        self.controller = controller
        self.view = controller.view
        self.scroll = scroll
    }

    init(view: NSView, scroll: NSScrollView) {
        self.view = view
        self.scroll = scroll
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.inspect() }
        }
    }

    func stop() {
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        controller = nil
        view = nil
        scroll = nil
    }

    private func inspect() {
        guard let view, let window = view.window,
              let root = window.contentView?.superview else { return }
        var current: NSViewController? = controller
        var controllers: [String] = []
        while let owner = current {
            controllers.append(String(describing: type(of: owner)))
            current = owner.parent
        }
        log("CONTROLLERS \(controllers.joined(separator: " > "))")
        snapshot("attached")
        func walk(_ view: NSView, path: String) {
            let name = String(describing: type(of: view))
            let next = "\(path)/\(name)"
            let rect = view.convert(view.bounds, to: nil)
            let owner = view === scroll ? " OUR_TABLE" : ""
            let layer = view.layer.map { " layer=\(type(of: $0)) hidden=\($0.isHidden) opacity=\($0.opacity)" } ?? ""
            log("VIEW \(next) id=\(ObjectIdentifier(view)) rect=\(rect) hidden=\(view.isHidden)"
                + " alpha=\(view.alphaValue)\(owner)\(layer)")
            if let native = view as? NSScrollView { observe(native, path: next) }
            for (index, child) in view.subviews.enumerated() { walk(child, path: "\(next)[\(index)]") }
        }
        walk(root, path: "")
        if Self.mode == "step" {
            for (delay, delta) in [(3.0, -320.0), (6.0, 640.0), (9.0, -320.0)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated { self?.step(by: delta) }
                }
            }
        }
    }

    private func observe(_ native: NSScrollView, path: String) {
        let clip = native.contentView
        clip.postsBoundsChangedNotifications = true
        notifications.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self, weak native] _ in
                MainActor.assumeIsolated {
                    guard let self, let native else { return }
                    let origin = native.contentView.bounds.origin
                    let id = ObjectIdentifier(native)
                    guard self.lastOrigins[id] != origin else { return }
                    self.lastOrigins[id] = origin
                    self.log("SCROLL \(path) id=\(id) ours=\(native === self.scroll)"
                        + " origin=\(origin) insets=\(native.contentInsets)"
                        + " document=\(String(describing: native.documentView.map { type(of: $0) }))")
                }
            })
    }

    private func snapshot(_ phase: String) {
        guard let view, let scroll else { return }
        log("SNAPSHOT \(phase) window=\(view.window?.windowNumber ?? -1)"
            + " key=\(view.window?.isKeyWindow == true)"
            + " titlebarTransparent=\(view.window?.titlebarAppearsTransparent == true)"
            + " style=\(view.window?.styleMask.rawValue ?? 0)"
            + " scroll=\(ObjectIdentifier(scroll)) frame=\(scroll.frame)"
            + " origin=\(scroll.contentView.bounds.origin) insets=\(scroll.contentInsets)"
            + " nativeSafe=\(scroll.safeAreaInsets) rootSafe=\(view.safeAreaInsets)"
            + " top=\(controller?.topEdge.view.frame ?? .zero)"
            + " bottom=\(controller?.bottomEdge.view.frame ?? .zero)")
    }

    private func step(by delta: CGFloat) {
        guard let scroll, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let minimum = -scroll.contentInsets.top
        let maximum = max(minimum, document.frame.height + scroll.contentInsets.bottom - clip.bounds.height)
        let next = min(maximum, max(minimum, clip.bounds.minY + delta))
        log("STEP table only \(clip.bounds.minY) -> \(next)")
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: next))
        scroll.reflectScrolledClipView(clip)
        snapshot("stepped")
    }

    private func log(_ line: String) {
        logger.notice("\(line, privacy: .public)")
    }
}
