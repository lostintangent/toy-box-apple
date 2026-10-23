import AppKit
import QuartzCore

/// `--benchmark-resize width|both|drag-width|drag-both` resizes the first window through three
/// rounds of 120 sizes, one size per display frame as a live resize does, then prints how long the
/// main thread stayed busy after each step and exits.
///
/// `width` and `both` set the window's frame directly. The `drag-` modes instead press the window's
/// bottom-right corner and drag it with mouse events, so AppKit runs its own live resize, the way a
/// person resizing the window does.
///
/// A step's busy time runs from its `setFrame` or drag event until the main run loop is about to
/// sleep again after the window resized, so it covers the synchronous layout and display and the
/// SwiftUI updates the resize schedules. A step that outlasts the display's frame delays the next
/// one, which the frame interval shows.
@MainActor
final class ResizeBenchmark: NSObject {
    enum Axis: String, Sendable { case width, both }

    enum Mode: String, Sendable {
        case width, both
        case dragWidth = "drag-width", dragBoth = "drag-both"

        var axis: Axis { self == .width || self == .dragWidth ? .width : .both }
        var drags: Bool { self == .dragWidth || self == .dragBoth }
    }

    static let stepsPerRound = 120
    static let rounds = 3

    let mode: Mode
    let channelID: String
    /// Live resizes defer what only matters once the size settles, and so do the benchmark's direct
    /// frame changes.
    private(set) var isResizing = false
    private weak var window: NSWindow?
    private var task: Task<Void, Never>?
    private var link: CADisplayLink?
    private var idleObserver: CFRunLoopObserver?
    private var sizes: [CGSize] = []
    private var next = 0
    private var stepStart: CFTimeInterval?
    private var idleAt: CFTimeInterval?
    private var lastTick: CFTimeInterval?
    private var frameDuration: CFTimeInterval = 1.0 / 60
    private var busy: [Double] = []
    private var setFrame: [Double] = []
    private var intervals: [Double] = []
    /// Where the drag holds the window, from its bottom-right corner.
    private var grip: CGVector?
    private var liveResizeSteps = 0
    /// The run loop can sleep before AppKit's resize loop takes a drag event, so a step's busy time
    /// ends only once the window has resized.
    private var hasResized = false
    private var finished: CheckedContinuation<Void, Never>?

    init(mode: Mode, channelID: String) {
        self.mode = mode
        self.channelID = channelID
    }

    /// The sizes one round passes through: out to the widest and back, as a drag does.
    static func sizes(axis: Axis) -> [CGSize] {
        let half = stepsPerRound / 2
        return (0..<stepsPerRound).map { step in
            let distance = CGFloat(step < half ? step : stepsPerRound - step)
            return CGSize(width: 1040 + distance * 8, height: axis == .both ? 700 + distance * 4 : 700)
        }
    }

    func attach(window: NSWindow, model: AppModel) {
        guard task == nil else { return }
        self.window = window
        window.isRestorable = false
        task = Task { [weak self] in
            guard let self else { return }
            let deadline = Date.now.addingTimeInterval(30)
            while model.catalog?.channel(id: channelID).state == nil, Date.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard model.catalog?.channel(id: channelID).state != nil else {
                FileHandle.standardError.write(Data("Resize benchmark failed: \(channelID) didn't load\n".utf8))
                exit(EXIT_FAILURE)
            }
            sizes = Array(repeating: Self.sizes(axis: mode.axis), count: Self.rounds).flatMap(\.self)
            window.setFrame(frame(for: sizes[0]), display: true)
            // Images, avatars and the inspector settle before the first measured step.
            try? await Task.sleep(for: .seconds(3))
            await run()
            print(report())
            fflush(stdout)
            // The first step presses the corner and the last releases it, so every step between
            // them runs in AppKit's live resize unless something, such as the pointer moving, ended
            // the drag early.
            if mode.drags, liveResizeSteps < sizes.count - 2 {
                FileHandle.standardError.write(Data(
                    "Resize benchmark failed: the drag ended after \(liveResizeSteps) steps. Leave the pointer still and run it again.\n".utf8))
                exit(EXIT_FAILURE)
            }
            exit(EXIT_SUCCESS)
        }
    }

    private func frame(for size: CGSize) -> NSRect {
        guard let window else { return .zero }
        return NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func run() async {
        guard let view = window?.contentView else { return }
        isResizing = !mode.drags
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true,
                                                          CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.stepStart != nil, self.idleAt == nil, self.hasResized else { return }
                self.idleAt = CACurrentMediaTime()
            }
        }
        idleObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let resized = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                             object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.hasResized = true }
        }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        await withCheckedContinuation { finished = $0 }
        link.invalidate()
        NotificationCenter.default.removeObserver(resized)
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        isResizing = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        frameDuration = link.targetTimestamp - link.timestamp
        if let stepStart {
            busy.append(((idleAt ?? now) - stepStart) * 1000)
            if let lastTick { intervals.append((now - lastTick) * 1000) }
        }
        lastTick = now
        guard next < sizes.count, let window else {
            stepStart = nil
            finished?.resume()
            finished = nil
            return
        }
        stepStart = now
        idleAt = nil
        hasResized = false
        if mode.drags {
            if window.inLiveResize { liveResizeSteps += 1 }
            drag(to: sizes[next], in: window, releasing: next == sizes.count - 1)
        } else {
            window.setFrame(frame(for: sizes[next]), display: true)
            setFrame.append((CACurrentMediaTime() - now) * 1000)
        }
        next += 1
    }

    /// Presses the window's bottom-right corner on the first step, then moves it so the window
    /// reaches `size`. AppKit's resize loop takes the events from the queue on its next pass.
    private func drag(to size: CGSize, in window: NSWindow, releasing: Bool) {
        func post(_ type: NSEvent.EventType, at point: NSPoint) {
            let location = NSPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        if grip == nil {
            let grip = CGVector(dx: 2, dy: 2)
            self.grip = grip
            post(.leftMouseDown, at: NSPoint(x: window.frame.maxX - grip.dx, y: window.frame.minY + grip.dy))
        }
        guard let grip else { return }
        let target = NSPoint(x: window.frame.minX + size.width - grip.dx, y: window.frame.maxY - size.height + grip.dy)
        post(releasing ? .leftMouseUp : .leftMouseDragged, at: target)
    }

    private func report() -> String {
        func line(_ name: String, _ values: [Double]) -> String {
            let sorted = values.sorted()
            func percentile(_ p: Double) -> Double {
                sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
            }
            return "\(name) p50 \(format(percentile(0.5))) p95 \(format(percentile(0.95))) max \(format(sorted.last ?? 0)) ms"
        }
        let budget = frameDuration * 1000
        let late = intervals.filter { $0 > budget * 1.5 }.count
        let input = mode.drags ? "live resize on \(liveResizeSteps) of \(busy.count) steps, ended at "
            + "\(Int(window?.frame.width ?? 0)) x \(Int(window?.frame.height ?? 0))" : line("setFrame", setFrame)
        return """
        Resize benchmark: \(mode.rawValue), \(busy.count) steps, \(format(budget)) ms frames
        \(line("busy", busy))
        \(input)
        \(line("frame interval", intervals)), \(late) of \(intervals.count) late
        """
    }

    private func format(_ value: Double) -> String { String(format: "%.1f", value) }
}
