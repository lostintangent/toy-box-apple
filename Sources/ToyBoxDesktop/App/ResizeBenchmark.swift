import AppKit
import QuartzCore

/// `--benchmark-resize width|both` drags the first window through three rounds of 120 sizes, one
/// size per display frame as a live resize does, then prints how long the main thread stayed busy
/// after each step and exits.
///
/// A step's busy time runs from its `setFrame` until the main run loop is about to sleep again,
/// so it covers the synchronous layout and display and the SwiftUI updates the resize schedules.
/// A step that outlasts the display's frame delays the next one, which the frame interval shows.
@MainActor
final class ResizeBenchmark: NSObject {
    enum Axis: String, Sendable { case width, both }

    static let stepsPerRound = 120
    static let rounds = 3

    let axis: Axis
    let channelID: String
    /// Live resizes defer what only matters once the size settles, and so does the benchmark.
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
    private var finished: CheckedContinuation<Void, Never>?

    init(axis: Axis, channelID: String) {
        self.axis = axis
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
            sizes = Array(repeating: Self.sizes(axis: axis), count: Self.rounds).flatMap(\.self)
            window.setFrame(frame(for: sizes[0]), display: true)
            // Images, avatars and the inspector settle before the first measured step.
            try? await Task.sleep(for: .seconds(3))
            await run()
            print(report())
            fflush(stdout)
            exit(EXIT_SUCCESS)
        }
    }

    private func frame(for size: CGSize) -> NSRect {
        guard let window else { return .zero }
        return NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func run() async {
        guard let view = window?.contentView else { return }
        isResizing = true
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true,
                                                          CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.stepStart != nil, self.idleAt == nil else { return }
                self.idleAt = CACurrentMediaTime()
            }
        }
        idleObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        await withCheckedContinuation { finished = $0 }
        link.invalidate()
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
        window.setFrame(frame(for: sizes[next]), display: true)
        setFrame.append((CACurrentMediaTime() - now) * 1000)
        next += 1
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
        return """
        Resize benchmark: \(axis.rawValue), \(busy.count) steps, \(format(budget)) ms frames
        \(line("busy", busy))
        \(line("setFrame", setFrame))
        \(line("frame interval", intervals)), \(late) of \(intervals.count) late
        """
    }

    private func format(_ value: Double) -> String { String(format: "%.1f", value) }
}
