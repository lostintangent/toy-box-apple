import AppKit
import ChannelClient
import Darwin
import Observation
import QuartzCore

/// `--benchmark launch|switch|messages|paging|scroll|idle|key` measures one scenario in the first window,
/// prints each result beside its budget and exits. `bun run benchmark` builds a release bundle and
/// runs the scenarios against `bun run perf-demo`, whose `/perf/messages` route streams the agent
/// messages that `messages` measures.
///
/// Busy time adds up the main run loop's passes, each from waking until it's about to sleep again,
/// so it covers events, SwiftUI updates, layout and display, but not waiting on the network. The
/// longest saturated span is the longest single pass. When work arrives faster than it finishes,
/// main stays awake through many frames, so a long span isn't always a stall. The longest frame gap
/// shows a stall. It's the longest stretch with no chance to draw, from the run loop waking or
/// exiting until it next exits or sleeps, which is where Core Animation commits.
///
/// - `launch`: when the channel's first frame appears after the process starts. No budget.
/// - `switch`: selects another catalog channel and back, four times each way. The first visit to the
///   other channel is cold, and the rest are warm. A warm switch's budget is on its longest
///   saturated span from the selection until the window settles, because a switch that lands over
///   several frames feels as slow as one long frame. It also counts the warm switches to a channel
///   that was still connected, then measures idle while the channel it left lingers and again once
///   it disconnects.
/// - `messages`: streams messages one at a time, for what each costs, then 50 of them 20 ms apart,
///   for the longest frame gap. It measures both at the first page of history and again with every
///   older page loaded.
/// - `paging`: scrolls the transcript to its top until every older page has loaded, and times each
///   from the scroll that crosses the transcript's paging edge until the page settles.
/// - `scroll`: a steady trackpad scroll up the transcript and back down, 15,000 pt each way at
///   2,400 pt a second, first at the first page of history and again with every older page loaded.
///   The wheel events go through the app's event queue, one per display frame, as a person's do.
///   A frame the display link skips is a dropped frame. The budget is on hitch time, the dropped
///   frames' milliseconds per second of scrolling. Hover runs only while the pointer is over the
///   transcript, which the results say. Each displayed frame also compares the first visible row's
///   movement with wheel deltas delivered since the preceding sample, with a 1-point drift budget.
/// - `idle`: a minute of wakeups and busy time once the channel settles. No budget.
/// - `key`: makes the window key, which a person's window is, and measures the whole process's CPU
///   while it sits there, first with the channel's own working agents and then with 20 working.
///   Animations that run only in the key window, like the working ellipsis, show up here.
@MainActor
final class PerformanceBenchmark {
    enum Scenario: String, CaseIterable, Sendable {
        case launch, messages, paging, scroll, idle, key
        case switching = "switch"
    }

    /// The performance pass's budgets, in milliseconds, at both 100 and 500 messages loaded.
    enum Budget {
        static let message = 16.0
        static let burstFrameGap = 100.0
        static let olderPage = 250.0
        static let warmSwitch = 150.0
        /// Milliseconds of dropped frames per second of scrolling. Under 5 reads as smooth.
        static let scrollHitches = 5.0
        static let scrollDrift = 1.0
        /// Percent of one core, for a key window that's only showing working agents.
        static let keyWindowCPU = 3.0
    }

    static let keyWindowSeconds = 15.0
    static let manyWorking = 20

    static let scrollSpeed = 2_400.0
    static let scrollDistance = 15_000.0
    /// How far a scroll stays from the transcript's ends, well clear of its paging edge.
    static let scrollMargin = 1_000.0

    static let burstCount = 50
    static let burstInterval = 20

    let scenario: Scenario
    let channelID: String
    private weak var window: NSWindow?
    private weak var model: AppModel?
    private var select: ((String) -> Void)?
    private var meter: MainRunLoopMeter?
    private var appearance: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var keyResigned = false

    init(scenario: Scenario, channelID: String) {
        self.scenario = scenario
        self.channelID = channelID
    }

    /// `select` changes the window's channel. Navigation requests reach only the key window, and a
    /// benchmark opens in the background.
    func attach(window: NSWindow, model: AppModel, select: @escaping (String) -> Void) {
        guard task == nil else { return }
        self.window = window
        self.model = model
        self.select = select
        window.isRestorable = false
        // A covered window skips drawing, so the benchmark's window comes forward without focus.
        window.orderFrontRegardless()
        let meter = MainRunLoopMeter()
        self.meter = meter
        // Launch watches for the catalog and the channel before either can arrive.
        let launch = scenario == .launch ? launchMoments(meter: meter) : nil
        Task.detached {
            try? await Task.sleep(for: .seconds(600))
            FileHandle.standardError.write(Data("Benchmark failed: the scenario didn't finish in 10 minutes\n".utf8))
            exit(EXIT_FAILURE)
        }
        task = Task {
            switch scenario {
            case .launch: if let launch { await self.launch(launch) }
            case .switching: await switching()
            case .messages: await messages()
            case .paging: await paging()
            case .scroll: await scrolling()
            case .idle: await idle()
            case .key: await keyWindow()
            }
            exit(EXIT_SUCCESS)
        }
    }

    // MARK: Scenarios

    private struct LaunchMoments {
        let window: Date
        let appeared: AsyncStream<Date>
        let catalog: AsyncStream<Date>
        let channel: AsyncStream<(applied: Date, frame: Date)>
    }

    private func launchMoments(meter: MainRunLoopMeter) -> LaunchMoments? {
        guard let window, let catalog = model?.catalog, let store = store(channelID) else { return nil }
        let now = Date.now
        // AppKit can show the window partway through the pass that builds it, before that pass
        // draws the channel, so the window appears on its own schedule.
        let (appeared, appearedContinuation) = AsyncStream.makeStream(of: Date.self)
        if window.occlusionState.contains(.visible) {
            appearedContinuation.yield(now)
        } else {
            appearance = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                    appearedContinuation.yield(.now)
                    appearedContinuation.finish()
                    if let appearance = self.appearance { NotificationCenter.default.removeObserver(appearance) }
                    self.appearance = nil
                }
            }
        }
        let (catalogLoaded, catalogContinuation) = AsyncStream.makeStream(of: Date.self)
        if catalog.state != nil {
            catalogContinuation.yield(now)
        } else {
            withObservationTracking { _ = catalog.state } onChange: {
                catalogContinuation.yield(.now)
                catalogContinuation.finish()
            }
        }
        let (channelLoaded, channelContinuation) = AsyncStream.makeStream(of: (applied: Date, frame: Date).self)
        if store.isLoaded {
            // A channel connected before the window opened first draws when the pass that opens
            // the window ends.
            meter.afterPass { _ in
                channelContinuation.yield((now, .now))
                channelContinuation.finish()
            }
        } else {
            withObservationTracking { _ = store.isLoaded } onChange: {
                let applied = Date.now
                // The pass that applies the snapshot ends once SwiftUI has drawn it.
                MainActor.assumeIsolated {
                    meter.afterPass { _ in
                        channelContinuation.yield((applied, .now))
                        channelContinuation.finish()
                    }
                }
            }
        }
        return LaunchMoments(window: now, appeared: appeared, catalog: catalogLoaded, channel: channelLoaded)
    }

    private func launch(_ moments: LaunchMoments) async {
        func first<Value>(_ stream: AsyncStream<Value>) async -> Value? {
            for await value in stream { return value }
            return nil
        }
        guard let meter, let catalog = await first(moments.catalog), let channel = await first(moments.channel),
              let appeared = await first(moments.appeared) else {
            fail("\(channelID) didn't load")
        }
        let settledAt = await settled(quiet: 1)
        let settled = Date.now.addingTimeInterval(settledAt - CACurrentMediaTime())
        let start = Self.processStart()
        func since(_ date: Date) -> String { String(format: "%.0f ms", date.timeIntervalSince(start) * 1000) }
        header()
        info("First content", "\(since(channel.frame)) after the process started. The window opened at "
             + "\(since(moments.window)) and appeared at \(since(appeared)), the catalog arrived at \(since(catalog)) "
             + "and the channel at \(since(channel.applied))")
        info("Settled", "\(since(settled)), after \(format(Self.mainThreadCPU() * 1000)) of main-thread CPU, with a "
             + "\(format(meter.longestGap * 1000)) longest frame gap and \(format(meter.longestSpan * 1000)) longest "
             + "saturated span after the window opened")
    }

    private func switching() async {
        await load(channelID)
        guard let other = model?.catalog?.channels.first(where: { $0.id != channelID })?.id else {
            fail("switch needs a second channel in the catalog")
        }
        guard let meter else { return }
        _ = await settled()
        header()
        var warm: [(frame: Double, span: Double, gap: Double, busy: Double, live: Double, wasLive: Bool)] = []
        var lastSelection = ContinuousClock.now
        for round in 0..<8 {
            let target = round.isMultiple(of: 2) ? other : channelID
            let isWarm = store(target)?.isLoaded == true
            try? await Task.sleep(for: .milliseconds(300))
            _ = await settled(quiet: 0.3)
            let wasLive = store(target)?.phase.isLive == true
            meter.reset()
            let start = CACurrentMediaTime()
            lastSelection = .now
            select?(target)
            let frame = await meter.passEnd()
            await load(target)
            // The main thread can't apply a connection's first event before the first frame ends.
            let live = wasLive ? start : CACurrentMediaTime()
            _ = await settled()
            let result = (frame: (frame - start) * 1000, span: meter.longestSpan * 1000, gap: meter.longestGap * 1000,
                          busy: meter.busy * 1000, live: (live - start) * 1000, wasLive: wasLive)
            if isWarm {
                warm.append(result)
            } else {
                info("Cold switch to \(target)", "first frame \(format(result.frame)), \(format(result.busy)) busy "
                     + "until it loaded and settled, \(format(result.span)) longest saturated span, "
                     + "\(format(result.gap)) longest frame gap")
            }
        }
        let spans = warm.map(\.span).sorted()
        check("Warm switch", "\(format(median(spans))) median longest saturated span, \(format(spans.last ?? 0)) worst, "
              + "\(format(median(warm.map(\.gap).sorted()))) median longest frame gap, "
              + "\(format(median(warm.map(\.frame).sorted()))) median first frame, "
              + "\(format(median(warm.map(\.busy).sorted()))) median busy, over \(warm.count) switches",
              value: median(spans), budget: Budget.warmSwitch)
        info("Warm switch connection", "\(warm.filter(\.wasLive).count) of \(warm.count) still connected when "
             + "selected, \(format(median(warm.map(\.live).sorted()))) median until live")
        await afterSwitching(since: lastSelection, channels: [channelID, other])
    }

    /// What leaving a channel costs: idle while its store lingers, then once the linger has ended.
    private func afterSwitching(since selection: ContinuousClock.Instant, channels: [String]) async {
        guard let meter else { return }
        func connected() -> Int { channels.filter { store($0).map { $0.phase != .idle } ?? false }.count }
        _ = await settled()
        let lingering = connected()
        meter.reset()
        var start = CACurrentMediaTime()
        try? await Task.sleep(for: .seconds(3))
        info("Idle after the last switch", "\(idleRate(since: start)), with \(lingering) of \(channels.count) channels connected")
        let linger = model?.connections.linger ?? .zero
        try? await Task.sleep(until: selection + linger + .seconds(1.5), clock: .continuous)
        let settledCount = connected()
        meter.reset()
        start = CACurrentMediaTime()
        try? await Task.sleep(for: .seconds(10))
        info("Idle once the linger ended", "\(idleRate(since: start)), with \(settledCount) of \(channels.count) channels connected")
    }

    private func idleRate(since start: CFTimeInterval) -> String {
        guard let meter else { return "" }
        let seconds = CACurrentMediaTime() - start
        return String(format: "%.1f wakeups and %.2f ms busy a second", Double(meter.passes) / seconds,
                      meter.busy * 1000 / seconds)
    }

    private func messages() async {
        await load(channelID)
        guard let store = store(channelID) else { return }
        _ = await settled()
        header()
        await measureMessages(in: store)
        let loaded = store.messages.count
        while store.hasOlderMessages {
            await store.loadOlder()
            _ = await settled(quiet: 0.3)
        }
        guard store.messages.count > loaded else {
            fail("\(channelID) has no older messages. Measure messages on history-demo from bun run perf-demo.")
        }
        // Older pages keep the visible row in place, so return to the latest message, where new
        // messages arrive.
        let gap = await scrollToEnd()
        guard gap < 2 else { fail("the transcript stayed \(Int(gap)) pt from the latest message") }
        await measureMessages(in: store)
    }

    private func measureMessages(in store: ChannelStore) async {
        guard let meter else { return }
        let loaded = store.messages.count
        var costs: [Double] = []
        // The first two warm up anything a new row builds once.
        for index in 0..<12 {
            try? await Task.sleep(for: .milliseconds(100))
            _ = await settled(quiet: 0.3)
            meter.reset()
            let last = await stream(1)
            await arrival(of: last, in: store)
            _ = await settled(quiet: 0.3)
            if index >= 2 { costs.append(meter.busy * 1000) }
        }
        let sorted = costs.sorted()
        check("Each message at \(loaded) loaded", "\(format(median(sorted))) median busy, \(format(sorted.last ?? 0)) "
              + "worst, over \(sorted.count) messages", value: median(sorted), budget: Budget.message)
        try? await Task.sleep(for: .seconds(1))
        _ = await settled()
        let before = store.messages.count
        meter.reset()
        let last = await stream(Self.burstCount, every: Self.burstInterval)
        await arrival(of: last, in: store, timeout: 120)
        _ = await settled()
        check("\(Self.burstCount) messages \(Self.burstInterval) ms apart at \(before) loaded",
              "\(format(meter.longestGap * 1000)) longest frame gap, \(format(meter.longestSpan * 1000)) longest "
              + "saturated span, \(format(meter.busy * 1000)) busy",
              value: meter.longestGap * 1000, budget: Budget.burstFrameGap)
    }

    /// Scrolls the transcript's own scroll view to its top, so the view's paging runs as it does
    /// for a person.
    private func paging() async {
        await load(channelID)
        guard let store = store(channelID), let meter else { return }
        _ = await settled()
        header()
        var page = 0
        while store.hasOlderMessages {
            try? await Task.sleep(for: .milliseconds(500))
            _ = await settled(quiet: 0.3)
            guard let scroll = transcriptScrollView() else { fail("there's no transcript scroll view") }
            // Lay out the oldest rows first, so the page's time leaves out the jump there.
            await scrollNearTop(scroll)
            let first = store.messages.first?.sequence ?? 0
            let loaded = store.messages.count
            meter.reset()
            let cpuStart = Self.mainThreadCPU()
            move(scroll, toTopOffset: 0)
            await until("scrolling to the top didn't load an older page", timeout: 20) {
                (store.messages.first?.sequence ?? 0) < first || !store.hasOlderMessages
            }
            guard store.messages.count > loaded else { break }
            _ = await settled(quiet: 1)
            let cpuMilliseconds = (Self.mainThreadCPU() - cpuStart) * 1000
            page += 1
            check("Older page \(page), \(loaded) to \(store.messages.count) loaded",
                  "\(format(meter.busy * 1000)) busy, \(format(meter.longestGap * 1000)) longest frame gap, "
                  + "\(format(meter.longestSpan * 1000)) longest saturated span, "
                  + "\(format(cpuMilliseconds)) main-thread CPU",
                  value: meter.busy * 1000, budget: Budget.olderPage)
        }
        guard page > 0 else {
            fail("\(channelID) has no older messages. Measure paging on history-demo from bun run perf-demo.")
        }
    }

    private func scrolling() async {
        await load(channelID)
        guard let store = store(channelID) else { return }
        // The first rows' images load before the first measurement.
        try? await Task.sleep(for: .seconds(1))
        _ = await settled()
        header()
        await measureScrolling(in: store)
        let loaded = store.messages.count
        while store.hasOlderMessages {
            await store.loadOlder()
            _ = await settled(quiet: 0.3)
        }
        guard store.messages.count > loaded else {
            fail("\(channelID) has no older messages. Measure scroll on scroll-demo from bun run perf-demo.")
        }
        let gap = await scrollToEnd()
        guard gap < 2 else { fail("the transcript stayed \(Int(gap)) pt from the latest message") }
        await measureScrolling(in: store)
    }

    /// Scrolls up from the latest message and back down the same distance.
    private func measureScrolling(in store: ChannelStore) async {
        guard let meter, let window else { return }
        guard let scroll = transcriptScrollView() else { fail("there's no transcript scroll view") }
        let geometry = BenchmarkScrollGeometry.isEnabled ? transcriptGeometrySource(in: scroll) : nil
        guard !BenchmarkScrollGeometry.isEnabled || geometry != nil else {
            fail("the transcript has no benchmark geometry source")
        }
        let loaded = store.messages.count
        let reach = min(Self.scrollDistance, offsetFromTop(scroll) - Self.scrollMargin)
        guard reach >= Self.scrollDistance / 2 else {
            fail("\(channelID) is \(Int(offsetFromTop(scroll))) pt tall, too short to scroll. "
                 + "Measure scroll on scroll-demo from bun run perf-demo.")
        }
        info("Pointer at \(loaded) loaded", pointerIsOver(scroll)
             ? "over the transcript, so hover runs as it does for a person"
             : "outside the transcript, so hover doesn't run")
        var distance = reach
        for up in [true, false] {
            try? await Task.sleep(for: .milliseconds(300))
            _ = await settled()
            let start = offsetFromTop(scroll)
            let gesture = WheelGesture(window: window, over: scroll, geometry: geometry,
                                       speed: up ? Self.scrollSpeed : -Self.scrollSpeed, distance: distance) { [weak self] in
                guard let self else { return true }
                return up ? self.offsetFromTop(scroll) < Self.scrollMargin
                    : self.gapToEnd(scroll) < Self.scrollMargin
            }
            meter.reset()
            let cpuStart = Self.mainThreadCPU()
            let frames = await gesture.run()
            let cpuMilliseconds = (Self.mainThreadCPU() - cpuStart) * 1000
            let busy = meter.busy
            guard frames.delivery.matches else {
                fail("wheel delivery mismatch: \(frames.delivery.postedEvents) posted, "
                     + "\(frames.delivery.deliveredEvents) delivered; "
                     + "\(frames.delivery.postedDelta) pt posted, \(frames.delivery.deliveredDelta) pt delivered; "
                     + "\(frames.delivery.creationFailures) event creation failures")
            }
            info("Wheel delivery \(up ? "up" : "down") at \(loaded) loaded",
                 "\(frames.delivery.deliveredEvents)/\(frames.delivery.postedEvents) events, "
                 + "\(frames.delivery.deliveredDelta)/\(frames.delivery.postedDelta) pt")
            let moved = abs(offsetFromTop(scroll) - start)
            guard moved > gesture.scrolled / 4 else {
                fail("the transcript moved \(Int(moved)) pt for \(Int(gesture.scrolled)) pt of wheel events")
            }
            let hitches = Double(frames.dropped) * frames.duration * 1000 / max(frames.seconds, 0.001)
            check("Scrolling \(up ? "up" : "down") \(Int(gesture.scrolled)) pt at \(loaded) loaded",
                  "\(frames.dropped) of \(frames.count) frames dropped, \(format(frames.longest * 1000)) longest frame, "
                  + String(format: "%.1f ms/s hitch time, main thread %.0f%% busy, "
                           + "%.1f ms main-thread CPU, %.1f pt native travel, %.1f CPU ms/1,000 pt",
                           hitches, busy / max(frames.seconds, 0.001) * 100,
                           cpuMilliseconds, Double(moved), cpuMilliseconds / Double(moved) * 1000),
                  value: hitches, budget: Budget.scrollHitches, unit: " ms/s")
            distance = gesture.scrolled
            guard geometry != nil else { continue }
            guard frames.drift.measuredFrames > 0, frames.drift.unmeasuredFrames == 0 else {
                fail("scroll drift measured \(frames.drift.measuredFrames) frame pairs, "
                     + "with \(frames.drift.unmeasuredFrames) unmeasurable frame pairs")
            }
            check("Row drift \(up ? "up" : "down") at \(loaded) loaded",
                  "\(frames.drift.measuredFrames) frame pairs, \(frames.drift.exceedingFrames) over 1 pt, "
                  + String(format: "%.3f pt maximum, %.3f pt total absolute drift",
                           frames.drift.maximum, frames.drift.total),
                  value: frames.drift.maximum, budget: Budget.scrollDrift, unit: " pt")
        }
    }

    /// Whether the person's pointer rests over the transcript, where hover tracks the rows that
    /// scroll under it.
    private func pointerIsOver(_ scroll: NSScrollView) -> Bool {
        guard let window else { return false }
        let pointer = NSEvent.mouseLocation
        return window.convertToScreen(scroll.convert(scroll.bounds, to: nil)).contains(pointer)
            && NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0) == window.windowNumber
    }

    private func idle() async {
        await load(channelID)
        guard let meter else { return }
        _ = await settled()
        try? await Task.sleep(for: .seconds(5))
        header()
        meter.reset()
        let start = CACurrentMediaTime()
        try? await Task.sleep(for: .seconds(60))
        let seconds = CACurrentMediaTime() - start
        info("Idle for \(Int(seconds.rounded())) s", String(format: "%.1f wakeups and %.2f ms busy a second, ",
                                                           Double(meter.passes) / seconds, meter.busy * 1000 / seconds)
             + "\(format(meter.longestGap * 1000)) longest frame gap, \(format(meter.longestSpan * 1000)) longest "
             + "saturated span")
    }

    private func keyWindow() async {
        await load(channelID)
        guard let window, let store = store(channelID) else { return }
        // bun run benchmark opens this scenario in front, so the app may already be active.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let deadline = CACurrentMediaTime() + 10
        while !window.isKeyWindow {
            guard CACurrentMediaTime() < deadline else {
                fail("the window didn't become key. Another app kept focus, so run key again while nobody is typing.")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        header()
        func working() -> Int {
            store.roster.count(where: { store.presence[$0.id]?.state == "working" })
        }
        await measureKeyWindow(window, label: "Key window with \(working()) working agents")
        await setWorking(Self.manyWorking)
        await until("\(Self.manyWorking) agents didn't start working") { working() >= Self.manyWorking }
        await measureKeyWindow(window, label: "Key window with \(working()) working agents")
    }

    /// Measures the process's CPU while the window stays key.
    private func measureKeyWindow(_ window: NSWindow, label: String) async {
        guard let meter else { return }
        // Work on every frame never settles, and that's what this measures, so it waits a fixed time
        // for anything that starts when the window becomes key or a row appears.
        try? await Task.sleep(for: .seconds(5))
        keyResigned = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.keyResigned = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        meter.reset()
        let start = CACurrentMediaTime()
        let process = Self.processCPU()
        let main = Self.mainThreadCPU()
        try? await Task.sleep(for: .seconds(Self.keyWindowSeconds))
        let seconds = CACurrentMediaTime() - start
        guard !keyResigned, window.isKeyWindow else {
            fail("the window stopped being key while it was measured, so run key again while nobody is typing.")
        }
        let percent = (Self.processCPU() - process) / seconds * 100
        check(label, String(format: "%.1f%% CPU, %.1f%% on the main thread, %.1f wakeups a second, over %.0f s",
                            percent, (Self.mainThreadCPU() - main) / seconds * 100, Double(meter.passes) / seconds,
                            seconds),
              value: percent, budget: Budget.keyWindowCPU, unit: "%")
    }

    /// Asks the fixture to make `count` agents working, adding members when the channel has fewer.
    private func setWorking(_ count: Int) async {
        guard let api = model?.api,
              var components = URLComponents(url: api.baseURL, resolvingAgainstBaseURL: false) else { fail("there's no server") }
        components.path = "/perf/working"
        components.queryItems = [.init(name: "channel", value: channelID), .init(name: "count", value: "\(count)")]
        guard let url = components.url else { fail("there's no server") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                fail("\(api.baseURL.absoluteString) can't set working agents: "
                     + "\(String(decoding: data, as: UTF8.self)). Run it against bun run perf-demo.")
            }
        } catch {
            fail("\(api.baseURL.absoluteString) can't set working agents: \(error.localizedDescription). "
                 + "Run it against bun run perf-demo.")
        }
    }

    // MARK: Waiting

    private func store(_ id: String) -> ChannelStore? { model?.catalog?.channel(id: id) }

    private func load(_ id: String) async {
        await until("\(id) didn't load") { [weak self] in
            guard let store = self?.store(id) else { return false }
            return store.isLoaded && store.phase.isLive
        }
    }

    private func arrival(of sequence: Int, in store: ChannelStore, timeout: Double = 30) async {
        await until("message \(sequence) didn't arrive", timeout: timeout) {
            (store.messages.last?.sequence ?? 0) >= sequence
        }
    }

    /// Waits until `condition` holds, checking again only when something it reads changes, so the
    /// wait itself doesn't wake the main thread.
    private func until(_ failure: String, timeout: Double = 30, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = CACurrentMediaTime() + timeout
        while !condition() {
            let remaining = deadline - CACurrentMediaTime()
            guard remaining > 0 else { fail(failure) }
            let signal = Signal()
            await withCheckedContinuation { continuation in
                signal.continuation = continuation
                withObservationTracking { _ = condition() } onChange: { Task { @MainActor in signal.fire() } }
                signal.timeout = Task.detached {
                    try? await Task.sleep(for: .seconds(remaining))
                    if !Task.isCancelled { await signal.fire() }
                }
            }
        }
    }

    /// Waits until no pass over a millisecond has run for `quiet` seconds, and returns when the last
    /// one ended.
    private func settled(quiet: Double = 0.5) async -> CFTimeInterval {
        guard let meter else { return CACurrentMediaTime() }
        // A change can resume the benchmark partway through the pass that applies it, so that
        // pass's work counts only once it ends.
        _ = await meter.passEnd()
        let deadline = CACurrentMediaTime() + 60
        while true {
            let wait = meter.lastWorkEnded + quiet - CACurrentMediaTime()
            guard wait > 0 else { return meter.lastWorkEnded }
            guard CACurrentMediaTime() < deadline else { fail("the main thread didn't settle for a minute") }
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    /// Asks the fixture to stream `count` agent messages and returns the last one's sequence.
    private func stream(_ count: Int, every interval: Int = 0) async -> Int {
        guard let api = model?.api,
              var components = URLComponents(url: api.baseURL, resolvingAgainstBaseURL: false) else { fail("there's no server") }
        components.path = "/perf/messages"
        components.queryItems = [.init(name: "channel", value: channelID), .init(name: "count", value: "\(count)"),
                                 .init(name: "interval", value: "\(interval)")]
        guard let url = components.url else { fail("there's no server") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        struct Streamed: Decodable { let first: Int, last: Int }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                fail("\(api.baseURL.absoluteString) can't stream benchmark messages: "
                     + "\(String(decoding: data, as: UTF8.self)). Run it against bun run perf-demo.")
            }
            return try JSONDecoder().decode(Streamed.self, from: data).last
        } catch {
            fail("\(api.baseURL.absoluteString) can't stream benchmark messages: \(error.localizedDescription). "
                 + "Run it against bun run perf-demo.")
        }
    }

    // MARK: Transcript scrolling

    /// The tallest scroll view in the window is the transcript's.
    private func transcriptScrollView() -> NSScrollView? {
        var found: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(visit)
        }
        if let content = window?.contentView { visit(content) }
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private func transcriptGeometrySource(in view: NSView) -> (any BenchmarkScrollGeometrySource)? {
        if let source = view as? any BenchmarkScrollGeometrySource { return source }
        if let scroll = view as? NSScrollView, let table = scroll.documentView as? NSTableView {
            return BenchmarkTableScrollGeometry(table: table, scroll: scroll)
        }
        for child in view.subviews {
            if let source = transcriptGeometrySource(in: child) { return source }
        }
        return nil
    }

    /// Moves the visible top `offset` points below the start of the content.
    private func move(_ scroll: NSScrollView, toTopOffset offset: Double) {
        guard let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let y = document.isFlipped ? offset - scroll.contentInsets.top
            : document.frame.height - clip.bounds.height - offset
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// How far the visible top sits below the start of the content.
    private func offsetFromTop(_ scroll: NSScrollView) -> Double {
        guard let document = scroll.documentView else { return .infinity }
        let clip = scroll.contentView.bounds
        return document.isFlipped ? clip.minY + scroll.contentInsets.top
            : document.frame.height - clip.maxY
    }

    /// Settles the visible top just short of where the transcript asks for an older page, until
    /// lazy row layout stops moving it.
    private func scrollNearTop(_ scroll: NSScrollView) async {
        let offset = 120.0
        var steady = 0
        for _ in 0..<40 where steady < 2 {
            move(scroll, toTopOffset: offset)
            _ = await settled(quiet: 0.3)
            steady = abs(offsetFromTop(scroll) - offset) < 2 ? steady + 1 : 0
        }
        guard steady == 2 else { fail("the transcript didn't stay near its top") }
    }

    /// How far the transcript's visible bottom sits above the end of its content.
    private func gapToEnd(_ scroll: NSScrollView) -> Double {
        guard let document = scroll.documentView else { return .infinity }
        let clip = scroll.contentView.bounds
        return document.isFlipped ? document.frame.height + scroll.contentInsets.bottom - clip.maxY
            : clip.minY + scroll.contentInsets.bottom
    }

    /// Scrolls to the end until lazy row layout stops moving it, and returns the gap left.
    private func scrollToEnd() async -> Double {
        guard let scroll = transcriptScrollView(), let document = scroll.documentView else { return .infinity }
        var atEnd = 0
        for _ in 0..<40 where atEnd < 3 {
            let clip = scroll.contentView
            let end = document.isFlipped ? document.frame.height - clip.bounds.height + scroll.contentInsets.bottom
                : -scroll.contentInsets.bottom
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: end))
            scroll.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(100))
            _ = await settled(quiet: 0.3)
            atEnd = gapToEnd(scroll) < 2 ? atEnd + 1 : 0
        }
        return gapToEnd(scroll)
    }

    // MARK: Reporting

    private func header() {
        let rate = window?.screen?.maximumFramesPerSecond ?? 60
        let visible = window?.occlusionState.contains(.visible) == true
        emit("Benchmark \(scenario.rawValue) on \(channelID): \(rate) Hz display, window \(visible ? "visible" : "covered")")
        info("Transcript", ProcessInfo.processInfo.environment["TOY_BOX_TRANSCRIPT"] ?? "lazy")
        if scenario == .scroll, !BenchmarkScrollGeometry.isEnabled {
            info("Frame drift", "disabled for the probe overhead control")
        }
    }

    private func check(_ name: String, _ detail: String, value: Double, budget: Double, unit: String = " ms") {
        emit("  \(name): \(detail) (budget \(Int(budget))\(unit)) \(value <= budget ? "ok" : "OVER")")
    }

    private func info(_ name: String, _ detail: String) {
        emit("  \(name): \(detail)")
    }

    private func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }

    private func format(_ milliseconds: Double) -> String { String(format: "%.1f ms", milliseconds) }

    private func median(_ sorted: [Double]) -> Double { sorted.isEmpty ? 0 : sorted[sorted.count / 2] }

    private func fail(_ reason: String) -> Never {
        FileHandle.standardError.write(Data("Benchmark failed: \(reason)\n".utf8))
        exit(EXIT_FAILURE)
    }

    /// Every thread's user and system CPU time, in seconds.
    private static func processCPU() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    /// The main thread's user and system CPU time, in seconds.
    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    }

    private static func processStart() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let time = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}

/// Row tops in viewport coordinates, increasing downward, including nearby rows for handoffs.
struct BenchmarkScrollGeometry: Equatable, Sendable {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--benchmark")
        && ProcessInfo.processInfo.environment["TOY_BOX_BENCHMARK_SCROLL_DRIFT"] != "0"

    var firstVisibleRow: String
    var rowTops: [String: CGFloat]
}

struct BenchmarkScrollDelivery: Equatable, Sendable {
    var postedEvents = 0
    var deliveredEvents = 0
    var postedDelta: CGFloat = 0
    var deliveredDelta: CGFloat = 0
    var creationFailures = 0

    var matches: Bool {
        creationFailures == 0 && postedEvents > 0 && postedEvents == deliveredEvents
            && postedDelta.isFinite && postedDelta == deliveredDelta
    }
}

@MainActor
protocol BenchmarkScrollGeometrySource: AnyObject {
    func benchmarkScrollGeometry() -> BenchmarkScrollGeometry?
}

@MainActor
final class BenchmarkTableScrollGeometry: BenchmarkScrollGeometrySource {
    private weak var table: NSTableView?
    private weak var scroll: NSScrollView?
    private let rowCount: Int

    init(table: NSTableView, scroll: NSScrollView) {
        self.table = table
        self.scroll = scroll
        rowCount = table.numberOfRows
    }

    func benchmarkScrollGeometry() -> BenchmarkScrollGeometry? {
        // Scroll fixtures never reorder rows. A structural change invalidates their native indices.
        guard let table, let scroll, table.isFlipped, table.numberOfRows == rowCount else { return nil }
        let clip = table.convert(scroll.contentView.bounds, from: scroll.contentView)
        let top = clip.minY + scroll.contentInsets.top
        let height = clip.height - scroll.contentInsets.top - scroll.contentInsets.bottom
        guard top.isFinite, height.isFinite, height > 0 else { return nil }
        let nearby = CGRect(x: 0, y: top - height, width: table.bounds.width, height: height * 3)
        let range = table.rows(in: nearby)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        var tops: [String: CGFloat] = [:]
        var first: String?
        for row in range.location..<min(rowCount, range.upperBound) {
            let rect = table.rect(ofRow: row)
            guard rect.minY.isFinite, rect.height.isFinite, rect.height > 0 else { return nil }
            let id = "table-row-\(row)"
            tops[id] = rect.minY - top
            if first == nil, rect.maxY > top, rect.minY < top + height { first = id }
        }
        guard let first else { return nil }
        return .init(firstVisibleRow: first, rowTops: tops)
    }
}

struct BenchmarkScrollDrift: Equatable, Sendable {
    private var previous: BenchmarkScrollGeometry?
    private var hasSampled = false
    private(set) var measuredFrames = 0
    private(set) var unmeasuredFrames = 0
    private(set) var exceedingFrames = 0
    private(set) var maximum = 0.0
    private(set) var total = 0.0

    /// A positive wheel delta moves a row downward. Input still queued for delivery is not included.
    mutating func sample(_ current: BenchmarkScrollGeometry?, scrollDelta: CGFloat) {
        defer {
            previous = current
            hasSampled = true
        }
        guard hasSampled else { return }
        guard let previous, let current, scrollDelta.isFinite,
              previous.rowTops[previous.firstVisibleRow]?.isFinite == true,
              current.rowTops[current.firstVisibleRow]?.isFinite == true else {
            unmeasuredFrames += 1
            return
        }
        let id = current.rowTops[previous.firstVisibleRow] != nil
            ? previous.firstVisibleRow : current.firstVisibleRow
        guard let before = previous.rowTops[id], let after = current.rowTops[id],
              before.isFinite, after.isFinite else {
            unmeasuredFrames += 1
            return
        }
        let drift = Double(abs(after - before - scrollDelta))
        measuredFrames += 1
        if drift > PerformanceBenchmark.Budget.scrollDrift { exceedingFrames += 1 }
        maximum = max(maximum, drift)
        total += drift
    }
}

/// One steady trackpad scroll over `scroll`, a step each display frame through the app's event
/// queue, the way a person's gesture arrives. Each step covers the time since the last frame, so a
/// late frame scrolls further, as the coalesced events of a held-up gesture do.
@MainActor
private final class WheelGesture: NSObject {
    struct Frames {
        /// Display frames the gesture spanned, including the ones it dropped.
        var count = 0
        var dropped = 0
        var longest: CFTimeInterval = 0
        var seconds: CFTimeInterval = 0
        var duration: CFTimeInterval = 1.0 / 60
        var drift = BenchmarkScrollDrift()
        var delivery = BenchmarkScrollDelivery()
    }

    private weak var window: NSWindow?
    private weak var scroll: NSScrollView?
    private let geometry: (any BenchmarkScrollGeometrySource)?
    /// Points a second. Positive scrolls toward the top.
    private let speed: Double
    private let distance: Double
    private let stop: @MainActor () -> Bool
    private(set) var scrolled = 0.0
    private var frames = Frames()
    private var link: CADisplayLink?
    private var first: CFTimeInterval?
    private var last: CFTimeInterval?
    private var carried = 0.0
    private var finished: CheckedContinuation<Void, Never>?
    private var sampledScroll: CGFloat = 0
    private var endedAt: CFTimeInterval?

    init(window: NSWindow, over scroll: NSScrollView, geometry: (any BenchmarkScrollGeometrySource)?,
         speed: Double, distance: Double,
         stop: @escaping @MainActor () -> Bool) {
        self.window = window
        self.scroll = scroll
        self.geometry = geometry
        self.speed = speed
        self.distance = distance
        self.stop = stop
    }

    func run() async -> Frames {
        guard let scroll else { return frames }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window {
                    self.frames.delivery.deliveredEvents += 1
                    self.frames.delivery.deliveredDelta += event.scrollingDeltaY
                }
            }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let link = scroll.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(scroll.window?.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
        await withCheckedContinuation { finished = $0 }
        link.invalidate()
        return frames
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard finished != nil else { return }
        if let geometry {
            frames.drift.sample(geometry.benchmarkScrollGeometry(),
                                scrollDelta: frames.delivery.deliveredDelta - sampledScroll)
        }
        sampledScroll = frames.delivery.deliveredDelta
        let now = link.timestamp
        frames.duration = link.targetTimestamp - link.timestamp
        let elapsed = last.map { now - $0 } ?? frames.duration
        if last != nil {
            let spanned = max(1, Int((elapsed / frames.duration).rounded()))
            frames.count += spanned
            frames.dropped += spanned - 1
            frames.longest = max(frames.longest, elapsed)
            frames.seconds = now - (first ?? now)
        } else {
            first = now
        }
        let begins = last == nil
        last = now
        if let endedAt {
            if frames.delivery.matches || now - endedAt >= 1 { finish() }
            return
        }
        guard scrolled < distance, !stop() else {
            post(.ended, delta: 0)
            endedAt = now
            return
        }
        let step = speed * elapsed + carried
        let whole = min(abs(step.rounded(.towardZero)), distance - scrolled).rounded(.up)
        carried = step - whole * (speed < 0 ? -1 : 1)
        post(begins ? .began : .changed, delta: Int32(whole * (speed < 0 ? -1 : 1)))
        scrolled += whole
    }

    private func finish() {
        finished?.resume()
        finished = nil
    }

    /// Posts a trackpad scroll event over the scroll view's center. Quartz's scroll event can't name
    /// a window, so the scroll fields move onto an AppKit event that does.
    private func post(_ phase: CGScrollPhase, delta: Int32) {
        guard let window, let scroll,
              let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0,
                                  wheel3: 0),
              let event = NSEvent.mouseEvent(with: .mouseMoved,
                                             location: scroll.convert(NSPoint(x: scroll.bounds.midX,
                                                                              y: scroll.bounds.midY), to: nil),
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 0, pressure: 0)?.cgEvent else {
            frames.delivery.creationFailures += 1
            return
        }
        event.type = .scrollWheel
        for field in Self.integerFields { event.setIntegerValueField(field, value: wheel.getIntegerValueField(field)) }
        for field in Self.fractionalFields { event.setDoubleValueField(field, value: wheel.getDoubleValueField(field)) }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        guard let posted = NSEvent(cgEvent: event) else {
            frames.delivery.creationFailures += 1
            return
        }
        frames.delivery.postedEvents += 1
        frames.delivery.postedDelta += posted.scrollingDeltaY
        NSApp.postEvent(posted, atStart: false)
    }

    /// Every field Quartz sets on a pixel scroll event. 101, 126 and 142 aren't named, but AppKit
    /// reads the deltas from them.
    private static let integerFields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventIsContinuous,
                                                        .scrollWheelEventPointDeltaAxis1]
        + [101].compactMap { CGEventField(rawValue: $0) }
    private static let fractionalFields: [CGEventField] = [.scrollWheelEventFixedPtDeltaAxis1]
        + [126, 142].compactMap { CGEventField(rawValue: $0) }
}

/// Resumes one wait once, whether a change or its timeout comes first.
@MainActor
private final class Signal {
    var continuation: CheckedContinuation<Void, Never>?
    var timeout: Task<Void, Never>?

    func fire() {
        timeout?.cancel()
        continuation?.resume()
        continuation = nil
    }
}

/// Times each pass of the main run loop, from waking until it's about to sleep again, and each frame
/// gap, from waking or exiting until the next exit or sleep.
@MainActor
private final class MainRunLoopMeter {
    private(set) var busy: Double = 0
    private(set) var passes = 0
    /// The longest pass. Main can stay awake through many frames when work keeps arriving.
    private(set) var longestSpan: Double = 0
    /// The longest stretch without a chance to draw. Core Animation commits as the run loop exits
    /// and before it sleeps, and AppKit dispatches each event between an exit and the next entry.
    private(set) var longestGap: Double = 0
    /// When the last pass over a millisecond ended.
    private(set) var lastWorkEnded = CACurrentMediaTime()
    /// The meter starts partway through a pass, which counts from then.
    private var wokeAt: CFTimeInterval? = CACurrentMediaTime()
    private var gapStart: CFTimeInterval? = CACurrentMediaTime()
    private var callbacks: [(CFTimeInterval) -> Void] = []

    init() {
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, .min) {
            [weak self] _, _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                self?.wokeAt = now
                self?.gapStart = now
            }
        }
        // The highest order runs after AppKit and SwiftUI have committed the pass's drawing.
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, .max) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.passEnded() }
        }
        // Also after Core Animation's commit, so a gap includes the commit that ends it.
        let exit = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.exit.rawValue, true, .max) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.gapEnded(startingAnother: true) }
        }
        for observer in [wake, sleep, exit] { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }

    func reset() {
        busy = 0
        passes = 0
        longestSpan = 0
        longestGap = 0
    }

    func afterPass(_ callback: @escaping (CFTimeInterval) -> Void) { callbacks.append(callback) }

    /// When the current pass ends.
    func passEnd() async -> CFTimeInterval {
        await withCheckedContinuation { continuation in afterPass { continuation.resume(returning: $0) } }
    }

    private func gapEnded(startingAnother: Bool) {
        let now = CACurrentMediaTime()
        if let gapStart { longestGap = max(longestGap, now - gapStart) }
        gapStart = startingAnother ? now : nil
    }

    private func passEnded() {
        gapEnded(startingAnother: false)
        let now = CACurrentMediaTime()
        if let wokeAt {
            let duration = now - wokeAt
            busy += duration
            passes += 1
            longestSpan = max(longestSpan, duration)
            if duration > 0.001 { lastWorkEnded = now }
        }
        wokeAt = nil
        let pending = callbacks
        callbacks = []
        for callback in pending { callback(now) }
    }
}
