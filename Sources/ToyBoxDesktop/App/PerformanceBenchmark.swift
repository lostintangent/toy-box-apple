import AppKit
import ChannelClient
import Darwin
import Observation
import QuartzCore

/// `--benchmark launch|switch|messages|paging|scroll|trackpad|idle|key` measures one scenario in the first window,
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
/// - `scroll`: precise, unphased wheel input up the transcript and back down, 15,000 pt each way at
///   2,400 pt a second, first at the first page of history and again with every older page loaded.
///   Wheel events go through the app-local queue, one per display frame. A plain table
///   first verifies the full applied distance and per-frame sampling in both directions. A short
///   already-visited transcript stretch then verifies that the same input reaches that container.
///   A frame the display link skips is a dropped frame. The budget is on hitch time, the dropped
///   frames' milliseconds per second of scrolling. Hover runs only while the pointer is over the
///   transcript, which the results say. Late-run-loop samples compare the first visible row's
///   movement with wheel deltas delivered since the preceding sample, with a 1-point drift budget.
/// - `trackpad`: an opt-in phased native check. It reports delivery and native travel after AppKit's
///   interpolation, not wheel-baseline performance or raw wheel-relative row drift.
/// - `idle`: a minute of wakeups and busy time once the channel settles. No budget.
/// - `key`: makes the window key, which a person's window is, and measures the whole process's CPU
///   while it sits there, first with the channel's own working agents and then with 20 working.
///   Animations that run only in the key window, like the working ellipsis, show up here.
@MainActor
final class PerformanceBenchmark {
    enum Scenario: String, CaseIterable, Sendable {
        case launch, messages, paging, scroll, trackpad, idle, key
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
            case .trackpad: await trackpad()
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
        guard !BenchmarkScrollGeometry.traceEnabled || BenchmarkScrollGeometry.isEnabled else {
            fail("signed frame tracing requires geometry sampling")
        }
        await load(channelID)
        guard let store = store(channelID) else { return }
        // The first rows' images load before the first measurement.
        try? await Task.sleep(for: .seconds(1))
        _ = await settled()
        header()
        info("Wheel driver", "unphased precise input through the app-local event queue")
        await verifyWheelDriver()
        if ProcessInfo.processInfo.environment["TOY_BOX_TRANSCRIPT"] == "native-control" { return }
        await verifyTranscriptInput()
        await measureScrolling(in: store)
        if BenchmarkScrollGeometry.traceEnabled { return }
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

    private func verifyWheelDriver() async {
        guard let original = window else { fail("the wheel driver has no window") }
        let control = BenchmarkNativeScrollControl(frame: original.frame, rows: 100)
        window = control.window
        defer {
            control.window.close()
            window = original
        }
        control.window.orderFrontRegardless()
        guard let scroll = transcriptScrollView(),
              let geometry = BenchmarkScrollGeometry.source(in: scroll) else {
            fail("the plain-table wheel driver control has no geometry")
        }
        move(scroll, toTopOffset: Self.scrollDistance + Self.scrollMargin * 2)
        for up in [true, false] {
            _ = await settled()
            let start = offsetFromTop(scroll)
            let gesture = WheelGesture(window: control.window, over: scroll, geometry: geometry,
                                       speed: up ? Self.scrollSpeed : -Self.scrollSpeed,
                                       distance: Self.scrollDistance) { false }
            let frames = await gesture.run()
            requireDelivery(frames.delivery)
            let moved = start - offsetFromTop(scroll)
            guard frames.delivery.matchesNativeTravel(moved),
                  frames.drift.measuredFrames > 0, frames.drift.unmeasuredFrames == 0,
                  frames.drift.maximum <= Budget.scrollDrift else {
                fail("plain-table driver control \(up ? "up" : "down"): "
                     + "\(frames.delivery.deliveredDelta) pt delivered, \(moved) pt applied; "
                     + "\(frames.drift.maximum) pt frame drift, "
                     + "\(frames.drift.unmeasuredFrames) missing frame pairs")
            }
            info("Wheel driver control \(up ? "up" : "down")",
                 "\(frames.delivery.deliveredEvents)/\(frames.delivery.postedEvents) events, "
                 + "\(abs(moved))/\(abs(frames.delivery.deliveredDelta)) pt applied, "
                 + "\(frames.drift.measuredFrames) frame pairs, \(frames.drift.maximum) pt maximum drift")
        }
    }

    private func verifyTranscriptInput() async {
        guard let window, let scroll = transcriptScrollView() else {
            fail("the transcript input control has no scroll view")
        }
        let warmDistance = min(1_000, offsetFromTop(scroll) - Self.scrollMargin)
        guard warmDistance >= 500 else { fail("the transcript is too short for the measured-row input control") }
        let warm = WheelGesture(window: window, over: scroll, geometry: nil,
                                speed: Self.scrollSpeed, distance: warmDistance) { false }
        requireDelivery(await warm.run().delivery)
        _ = await settled()
        // Scroll back within the rows just visited, so estimates can't change the native distance.
        let distance = min(400, gapToEnd(scroll) / 2)
        guard distance >= 100 else { fail("the measured-row input control has no room before the end") }
        let start = offsetFromTop(scroll)
        let gesture = WheelGesture(window: window, over: scroll, geometry: nil,
                                   speed: -Self.scrollSpeed, distance: distance) { false }
        let frames = await gesture.run()
        requireDelivery(frames.delivery)
        let moved = start - offsetFromTop(scroll)
        guard frames.delivery.matchesNativeTravel(moved) else {
            fail("measured-row transcript input control: \(frames.delivery.deliveredDelta) pt delivered, "
                 + "\(moved) pt applied")
        }
        info("Measured-row transcript input control",
             "\(frames.delivery.deliveredEvents)/\(frames.delivery.postedEvents) events, "
             + "\(abs(moved))/\(abs(frames.delivery.deliveredDelta)) pt applied")
        let gap = await scrollToEnd()
        guard gap < 2 else { fail("the transcript input control didn't restore the latest message") }
    }

    private func trackpad() async {
        await load(channelID)
        _ = await settled()
        header()
        info("Phased trackpad check",
             "own-PID WindowServer delivery, requires Accessibility; not a wheel baseline or a row-drift gate")
        guard let window, let scroll = transcriptScrollView() else { fail("there's no transcript scroll view") }
        let distance = min(Self.scrollDistance, offsetFromTop(scroll) - Self.scrollMargin)
        guard distance >= Self.scrollDistance / 2 else { fail("the transcript is too short for the trackpad check") }
        let start = offsetFromTop(scroll)
        let gesture = WheelGesture(window: window, over: scroll, geometry: nil, speed: Self.scrollSpeed,
                                   distance: distance, phased: true) { self.offsetFromTop(scroll) < Self.scrollMargin }
        let frames = await gesture.run()
        requireDelivery(frames.delivery)
        let moved = abs(offsetFromTop(scroll) - start)
        guard moved > gesture.scrolled / 4 else { fail("the phased trackpad input didn't move the transcript") }
        info("Phased trackpad input",
             "\(frames.delivery.deliveredEvents)/\(frames.delivery.postedEvents) events, "
             + "\(frames.delivery.deliveredDelta) pt delivered, \(moved) pt native travel after a 1 s end drain. "
             + "AppKit interpolation is included in native travel.")
    }

    private func requireDelivery(_ delivery: BenchmarkScrollDelivery) {
        guard delivery.matches else {
            fail("wheel delivery mismatch: \(delivery.postedEvents) posted, "
                 + "\(delivery.deliveredEvents) delivered; "
                 + "\(delivery.postedDelta) pt posted, \(delivery.deliveredDelta) pt delivered; "
                 + "\(delivery.creationFailures) creation and \(delivery.observationFailures) observation failures")
        }
    }

    /// Scrolls up from the latest message and back down the same distance.
    private func measureScrolling(in store: ChannelStore) async {
        guard let meter, let window else { return }
        guard let scroll = transcriptScrollView() else { fail("there's no transcript scroll view") }
        let geometry = BenchmarkScrollGeometry.isEnabled ? BenchmarkScrollGeometry.source(in: scroll) : nil
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
            if !frames.trace.isEmpty {
                do {
                    let encoder = JSONEncoder()
                    for frame in frames.trace {
                        let data = try encoder.encode(frame)
                        info("Scroll trace \(up ? "up" : "down") at \(loaded) loaded",
                             String(decoding: data, as: UTF8.self))
                    }
                } catch { fail("couldn't encode the signed scroll trace: \(error.localizedDescription)") }
            }
            requireDelivery(frames.delivery)
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
            if BenchmarkScrollGeometry.traceEnabled {
                guard frames.displayLinkDrift.measuredFrames == frames.drift.measuredFrames,
                      frames.displayLinkDrift.unmeasuredFrames == 0 else {
                    fail("the diagnostic display-link sampler had incomplete geometry coverage")
                }
                info("Diagnostic display-link drift \(up ? "up" : "down") at \(loaded) loaded",
                     "\(frames.displayLinkDrift.measuredFrames) frame pairs, "
                     + "\(frames.displayLinkDrift.exceedingFrames) over 1 pt, "
                     + String(format: "%.3f pt maximum, not an acceptance metric", frames.displayLinkDrift.maximum))
                return
            }
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
        info("Before key activation", keyWindowDiagnostics(window))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        info("After key activation request", keyWindowDiagnostics(window))
        let deadline = CACurrentMediaTime() + 10
        while !BenchmarkKeyWindowState.capture(window).canMeasure {
            guard CACurrentMediaTime() < deadline else {
                fail("the key scenario needs an active, visible, uncovered window. \(keyWindowDiagnostics(window))")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        info("Key window ready", keyWindowDiagnostics(window))
        header()
        func working() -> Int {
            store.roster.count(where: { store.presence[$0.id]?.state == "working" })
        }
        await measureKeyWindow(window, label: "Key window with \(working()) working agents")
        await setWorking(Self.manyWorking)
        await until("\(Self.manyWorking) agents didn't start working") { working() >= Self.manyWorking }
        await measureKeyWindow(window, label: "Key window with \(working()) working agents")
    }

    /// Measures the process's CPU only while its active, key window remains exposed.
    private func measureKeyWindow(_ window: NSWindow, label: String) async {
        guard let meter else { return }
        // Work on every frame never settles, and that's what this measures, so it waits a fixed time
        // for anything that starts when the window becomes key or a row appears.
        try? await Task.sleep(for: .seconds(5))
        requireMeasurableKeyWindow(window)
        let validate: @Sendable (Notification) -> Void = { [weak self, weak window] note in
            let closing = note.name == NSWindow.willCloseNotification
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                if closing { self.fail("the key scenario's window closed during measurement") }
                self.requireMeasurableKeyWindow(window)
            }
        }
        let notifications: [(Notification.Name, NSObject)] = [
            (NSWindow.didResignKeyNotification, window),
            (NSWindow.didChangeOcclusionStateNotification, window),
            (NSWindow.didMiniaturizeNotification, window),
            (NSWindow.willCloseNotification, window),
            (NSApplication.didResignActiveNotification, NSApp),
            (NSApplication.didHideNotification, NSApp),
        ]
        let observers = notifications.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main, using: validate)
        }
        defer { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
        meter.reset()
        let start = CACurrentMediaTime()
        let process = Self.processCPU()
        let main = Self.mainThreadCPU()
        try? await Task.sleep(for: .seconds(Self.keyWindowSeconds))
        let seconds = CACurrentMediaTime() - start
        requireMeasurableKeyWindow(window)
        let percent = (Self.processCPU() - process) / seconds * 100
        check(label, String(format: "%.1f%% CPU, %.1f%% on the main thread, %.1f wakeups a second, over %.0f s",
                            percent, (Self.mainThreadCPU() - main) / seconds * 100, Double(meter.passes) / seconds,
                            seconds),
              value: percent, budget: Budget.keyWindowCPU, unit: "%")
    }

    private func requireMeasurableKeyWindow(_ window: NSWindow) {
        guard BenchmarkKeyWindowState.capture(window).canMeasure else {
            fail("the key scenario lost its active, visible, uncovered window. \(keyWindowDiagnostics(window))")
        }
    }

    private func keyWindowDiagnostics(_ window: NSWindow) -> String {
        let state = BenchmarkKeyWindowState.capture(window)
        let policy = NSRunningApplication.current.activationPolicy.rawValue
        let appWindows = NSApp.windows.map {
            "\($0.windowNumber):\(BenchmarkKeyWindowState.capture($0))"
        }.joined(separator: "; ")
        let server: String
        if let records = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
            let own = records.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid()) }
            server = own.isEmpty ? "no WindowServer records for pid \(getpid())" : own.map {
                let number = String(describing: $0[kCGWindowNumber as String] ?? "unknown number")
                let onscreen = String(describing: $0[kCGWindowIsOnscreen as String] ?? "unknown visibility")
                let owner = String(describing: $0[kCGWindowOwnerName as String] ?? "unknown owner")
                return "\(number):onscreen=\(onscreen), owner=\(owner)"
            }.joined(separator: "; ")
        } else {
            server = "WindowServer list unavailable"
        }
        return "\(state), policy=\(policy), window=\(window.windowNumber), frame=\(window.frame), "
            + "app windows=[\(appWindows)], WindowServer=[\(server)]"
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
        if scenario == .scroll, BenchmarkScrollGeometry.traceEnabled {
            info("Signed frame trace", "first-page upward gesture only, buffered until CPU measurement ends")
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

struct BenchmarkKeyWindowState: Equatable, Sendable, CustomStringConvertible {
    let active: Bool
    let hidden: Bool
    let key: Bool
    let visible: Bool
    let miniaturized: Bool
    let exposed: Bool

    var canMeasure: Bool { active && !hidden && key && visible && !miniaturized && exposed }
    var description: String {
        "active=\(active), hidden=\(hidden), key=\(key), visible=\(visible), "
            + "miniaturized=\(miniaturized), exposed=\(exposed)"
    }

    @MainActor
    static func capture(_ window: NSWindow) -> Self {
        .init(active: NSApp.isActive, hidden: NSApp.isHidden, key: window.isKeyWindow,
              visible: window.isVisible, miniaturized: window.isMiniaturized,
              exposed: window.occlusionState.contains(.visible))
    }
}

/// Row tops in viewport coordinates, increasing downward, including nearby rows for handoffs.
struct BenchmarkScrollGeometry: Equatable, Sendable {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--benchmark")
        && ProcessInfo.processInfo.environment["TOY_BOX_BENCHMARK_SCROLL_DRIFT"] != "0"
    static let traceEnabled = ProcessInfo.processInfo.environment["TOY_BOX_BENCHMARK_SCROLL_TRACE"] == "1"

    var firstVisibleRow: String
    var rowTops: [String: CGFloat]
    var reportedTops: [String: CGFloat] = [:]

    @MainActor
    static func source(in scroll: NSScrollView) -> (any BenchmarkScrollGeometrySource)? {
        func find(in view: NSView) -> (any BenchmarkScrollGeometrySource)? {
            guard view === scroll || !(view is NSScrollView) else { return nil }
            if let source = view as? any BenchmarkScrollGeometrySource { return source }
            if let table = view as? NSTableView {
                return BenchmarkTableScrollGeometry(table: table, scroll: scroll)
            }
            for child in view.subviews {
                if let source = find(in: child) { return source }
            }
            return nil
        }
        return find(in: scroll)
    }
}

struct BenchmarkScrollDelivery: Equatable, Sendable {
    var postedEvents = 0
    var deliveredEvents = 0
    var postedDelta: CGFloat = 0
    var deliveredDelta: CGFloat = 0
    var creationFailures = 0
    var observationFailures = 0

    var matches: Bool {
        creationFailures == 0 && observationFailures == 0 && postedEvents > 0 && postedEvents == deliveredEvents
            && postedDelta.isFinite && postedDelta == deliveredDelta
    }

    func matchesNativeTravel(_ movement: CGFloat) -> Bool {
        matches && movement.isFinite && abs(movement - deliveredDelta) <= 0.000_001
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

@MainActor
private final class BenchmarkNativeScrollControl: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    private let rows: Int

    init(frame: CGRect, rows: Int) {
        self.rows = rows
        window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Native table scroll control"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: frame.size))
        scroll.hasVerticalScroller = true
        let table = NSTableView(frame: CGRect(x: 0, y: 0, width: frame.width, height: CGFloat(rows) * 400))
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.rowHeight = 400
        table.selectionHighlightStyle = .none
        let column = NSTableColumn(identifier: .init("message"))
        column.width = frame.width
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        window.contentView = scroll
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("control-row")
        let label = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.stringValue = "Native control row \(row + 1)"
        return label
    }
}

struct BenchmarkScrollDrift: Equatable, Sendable {
    struct Sample: Equatable, Sendable, Encodable {
        var rowID: String
        var before: CGFloat
        var after: CGFloat
        var wheel: CGFloat
        var residual: CGFloat
        var reportedBefore: CGFloat?
        var reportedAfter: CGFloat?
    }

    private var previous: BenchmarkScrollGeometry?
    private var hasSampled = false
    private(set) var measuredFrames = 0
    private(set) var unmeasuredFrames = 0
    private(set) var exceedingFrames = 0
    private(set) var maximum = 0.0
    private(set) var total = 0.0

    /// A positive wheel delta moves a row downward. Input still queued for delivery is not included.
    @discardableResult
    mutating func sample(_ current: BenchmarkScrollGeometry?, scrollDelta: CGFloat) -> Sample? {
        defer {
            previous = current
            hasSampled = true
        }
        guard hasSampled else { return nil }
        guard let previous, let current, scrollDelta.isFinite,
              previous.rowTops[previous.firstVisibleRow]?.isFinite == true,
              current.rowTops[current.firstVisibleRow]?.isFinite == true else {
            unmeasuredFrames += 1
            return nil
        }
        let id = current.rowTops[previous.firstVisibleRow] != nil
            ? previous.firstVisibleRow : current.firstVisibleRow
        guard let before = previous.rowTops[id], let after = current.rowTops[id],
              before.isFinite, after.isFinite else {
            unmeasuredFrames += 1
            return nil
        }
        let residual = after - before - scrollDelta
        let drift = Double(abs(residual))
        measuredFrames += 1
        if drift > PerformanceBenchmark.Budget.scrollDrift { exceedingFrames += 1 }
        maximum = max(maximum, drift)
        total += drift
        return .init(rowID: id, before: before, after: after, wheel: scrollDelta, residual: residual,
                     reportedBefore: previous.reportedTops[id], reportedAfter: current.reportedTops[id])
    }
}

/// One steady scroll over `scroll`, a step each display frame. Unphased wheel input uses the
/// app-local queue. Opt-in phased input uses WindowServer delivery to this PID only.
/// Each step covers the time since the last frame, so a
/// late frame scrolls further, as the coalesced events of a held-up gesture do.
@MainActor
private final class WheelGesture: NSObject {
    struct Trace: Encodable {
        var phase: String
        var time: CFTimeInterval
        var sampleTime: CFTimeInterval
        var sample: BenchmarkScrollDrift.Sample?
        var nativeTop: CGFloat?
        var documentHeight: CGFloat?
        var postedEvents: Int
        var deliveredEvents: Int
        var deliveredDelta: CGFloat
    }

    struct Frames {
        /// Display frames the gesture spanned, including the ones it dropped.
        var count = 0
        var dropped = 0
        var longest: CFTimeInterval = 0
        var seconds: CFTimeInterval = 0
        var duration: CFTimeInterval = 1.0 / 60
        var drift = BenchmarkScrollDrift()
        var displayLinkDrift = BenchmarkScrollDrift()
        var delivery = BenchmarkScrollDelivery()
        var trace: [Trace] = []
    }

    private weak var window: NSWindow?
    private weak var scroll: NSScrollView?
    private let geometry: (any BenchmarkScrollGeometrySource)?
    /// Points a second. Positive scrolls toward the top.
    private let speed: Double
    private let distance: Double
    private let phased: Bool
    private let stop: @MainActor () -> Bool
    private(set) var scrolled = 0.0
    private var frames = Frames()
    private var link: CADisplayLink?
    private var first: CFTimeInterval?
    private var last: CFTimeInterval?
    private var carried = 0.0
    private var finished: CheckedContinuation<Void, Never>?
    private var displayLinkSampledScroll: CGFloat = 0
    private var endedAt: CFTimeInterval?
    private var pendingLateTime: CFTimeInterval?
    private var sampledScroll: CGFloat = 0
    private var finishAfterLateSample = false

    init(window: NSWindow, over scroll: NSScrollView, geometry: (any BenchmarkScrollGeometrySource)?,
         speed: Double, distance: Double, phased: Bool = false,
         stop: @escaping @MainActor () -> Bool) {
        self.window = window
        self.scroll = scroll
        self.geometry = geometry
        self.speed = speed
        self.distance = distance
        self.phased = phased
        self.stop = stop
    }

    func run() async -> Frames {
        guard let scroll else { return frames }
        let stopObserving = observeDelivery()
        defer { stopObserving() }
        if let geometry {
            let initial = geometry.benchmarkScrollGeometry()
            frames.drift.sample(initial, scrollDelta: 0)
            if BenchmarkScrollGeometry.traceEnabled {
                frames.displayLinkDrift.sample(initial, scrollDelta: 0)
            }
        }
        let lateObserver: CFRunLoopObserver?
        if geometry != nil {
            let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
            guard let observer = CFRunLoopObserverCreateWithHandler(
                nil, activities, true, CFIndex.max - 1, { [weak self] _, _ in
                MainActor.assumeIsolated { self?.sampleAtEndOfLoop() }
            }) else {
                FileHandle.standardError.write(Data("Benchmark failed: couldn't install the end-of-loop sampler\n".utf8))
                exit(EXIT_FAILURE)
            }
            lateObserver = observer
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        } else {
            lateObserver = nil
        }
        defer {
            if let lateObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), lateObserver, .commonModes) }
        }
        let link = scroll.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(scroll.window?.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
        await withCheckedContinuation { finished = $0 }
        link.invalidate()
        return frames
    }

    private func observeDelivery() -> () -> Void {
        if !phased {
            guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window === self.window {
                        self.frames.delivery.deliveredEvents += 1
                        self.frames.delivery.deliveredDelta += event.scrollingDeltaY
                        if !event.phase.isEmpty { self.frames.delivery.observationFailures += 1 }
                    }
                }
                return event
            }) else {
                FileHandle.standardError.write(Data("Benchmark failed: couldn't observe app-local wheel delivery\n".utf8))
                exit(EXIT_FAILURE)
            }
            return { NSEvent.removeMonitor(monitor) }
        }
        guard CGPreflightPostEventAccess() else {
            FileHandle.standardError.write(Data(
                "Benchmark failed: Toy Box Benchmark needs Accessibility permission for own-PID wheel delivery\n".utf8))
            exit(EXIT_FAILURE)
        }
        guard let tap = CGEvent.tapCreateForPid(
            pid: getpid(), place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
            callback: { _, type, event, context in
            MainActor.assumeIsolated {
                guard let context else { return }
                let gesture = Unmanaged<WheelGesture>.fromOpaque(context).takeUnretainedValue()
                if type == .scrollWheel, let native = NSEvent(cgEvent: event) {
                    gesture.frames.delivery.deliveredEvents += 1
                    gesture.frames.delivery.deliveredDelta += native.scrollingDeltaY
                } else {
                    gesture.frames.delivery.observationFailures += 1
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            FileHandle.standardError.write(Data("Benchmark failed: couldn't observe own-process wheel delivery\n".utf8))
            exit(EXIT_FAILURE)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(tap)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard finished != nil else { return }
        if geometry != nil { pendingLateTime = link.timestamp }
        if BenchmarkScrollGeometry.traceEnabled, let geometry {
            let sample = frames.displayLinkDrift.sample(
                geometry.benchmarkScrollGeometry(),
                scrollDelta: frames.delivery.deliveredDelta - displayLinkSampledScroll)
            appendTrace(sample, at: link.timestamp, phase: "display-link")
            displayLinkSampledScroll = frames.delivery.deliveredDelta
        }
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
            if (frames.delivery.matches && now - endedAt >= (phased ? 1 : 0)) || now - endedAt >= 2 {
                if geometry != nil { finishAfterLateSample = true } else { finish() }
            }
            return
        }
        if begins, phased {
            post(.began, delta: 0)
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
        post(.changed, delta: Int32(whole * (speed < 0 ? -1 : 1)))
        scrolled += whole
    }

    private func finish() {
        finished?.resume()
        finished = nil
    }

    private func sampleAtEndOfLoop() {
        guard let time = pendingLateTime, let geometry else { return }
        pendingLateTime = nil
        let sample = frames.drift.sample(geometry.benchmarkScrollGeometry(),
                                        scrollDelta: frames.delivery.deliveredDelta - sampledScroll)
        sampledScroll = frames.delivery.deliveredDelta
        if BenchmarkScrollGeometry.traceEnabled { appendTrace(sample, at: time, phase: "end-of-loop") }
        if finishAfterLateSample { finish() }
    }

    private func appendTrace(_ sample: BenchmarkScrollDrift.Sample?, at time: CFTimeInterval, phase: String) {
        frames.trace.append(.init(
            phase: phase, time: time - (first ?? time), sampleTime: CACurrentMediaTime() - (first ?? time),
            sample: sample,
            nativeTop: scroll.map { $0.contentView.bounds.minY + $0.contentInsets.top },
            documentHeight: scroll?.documentView?.frame.height,
            postedEvents: frames.delivery.postedEvents,
            deliveredEvents: frames.delivery.deliveredEvents,
            deliveredDelta: frames.delivery.deliveredDelta))
    }

    private func post(_ phase: CGScrollPhase, delta: Int32) {
        guard let window, let scroll,
              let posted = BenchmarkWheelEvent.make(
                  delta: delta, phase: phased ? phase : nil,
                  location: scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil),
                  windowNumber: window.windowNumber) else {
            frames.delivery.creationFailures += 1
            return
        }
        frames.delivery.postedEvents += 1
        frames.delivery.postedDelta += posted.scrollingDeltaY
        if !phased {
            NSApp.postEvent(posted, atStart: false)
            return
        }
        guard let event = posted.cgEvent else {
            frames.delivery.creationFailures += 1
            return
        }
        event.postToPid(getpid())
    }
}

enum BenchmarkWheelEvent {
    /// Quartz's scroll event can't name a window, so its fields move onto an AppKit event that does.
    static func make(delta: Int32, phase: CGScrollPhase? = nil, location: NSPoint, windowNumber: Int) -> NSEvent? {
        guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: delta, wheel2: 0, wheel3: 0),
              let event = NSEvent.mouseEvent(
                  with: .mouseMoved, location: location, modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                  context: nil, eventNumber: 0, clickCount: 0, pressure: 0)?.cgEvent else { return nil }
        event.type = .scrollWheel
        for field in Self.integerFields { event.setIntegerValueField(field, value: wheel.getIntegerValueField(field)) }
        for field in Self.fractionalFields { event.setDoubleValueField(field, value: wheel.getDoubleValueField(field)) }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        return NSEvent(cgEvent: event)
    }

    /// Pixel delta fields consumed by AppKit. 101, 126 and 142 have no public names.
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
