import AppKit
import ChannelClient
import ChannelIntelligence
import ChannelKit
import Observation

/// A once-per-morning recap. Reading history here never changes a channel's store or read receipt.
@MainActor @Observable
final class MorningDigest {
    nonisolated static let enabledKey = "morningDigestEnabled"
    nonisolated static let timeKey = "morningDigestMinutes"
    nonisolated static let lastRunKey = "morningDigestLastRun"
    nonisolated static let category = "morningDigest"

    struct Content: Equatable {
        struct Line: Equatable {
            var channelID: String
            var name: String
            var count: Int
            var text: String
        }

        var lines: [Line]
        var busiest: Line? { lines.first }
        var body: String { lines.map { "\($0.name): \($0.text)" }.joined(separator: "\n") }
    }

    struct Host {
        var server: () -> String
        var authorized: () async -> Bool
        var build: (ChannelDigestWindow) async throws -> Content
        var deliver: (Content, String, String) async throws -> Void
    }

    private let host: Host
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let allowed: Bool
    private let testAllowed: Bool
    private(set) var error: String?
    private(set) var isRunning = false
    private var timer: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(host: Host, defaults: UserDefaults = .standard, allowed: Bool, testAllowed: Bool = false,
         now: @escaping () -> Date = { .now },
         calendar: @escaping () -> Calendar = { .autoupdatingCurrent }) {
        self.host = host
        self.defaults = defaults
        self.allowed = allowed
        self.testAllowed = testAllowed
        self.now = now
        self.calendar = calendar
    }

    isolated deinit {
        timer?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func start() {
        guard allowed, timer == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                let seconds = 60 - (self?.now().timeIntervalSince1970 ?? 0).truncatingRemainder(dividingBy: 60)
                do { try await Task.sleep(for: .seconds(max(1, seconds))) }
                catch { return }
            }
        }
    }

    static func isAllowed(_ options: LaunchOptions, bundleID: String?,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        bundleID == "dev.toybox.desktop" && options.allowsUserIntegrations(environment: environment)
    }

    func check() async {
        guard allowed, !isRunning,
              defaults.object(forKey: Self.enabledKey) as? Bool != false,
              defaults.bool(forKey: "notificationsEnabled") else { return }
        let server = host.server()
        let coverageKey = "morningDigestThrough.\(server)"
        let minutes = defaults.object(forKey: Self.timeKey) as? Int ?? 480
        guard let window = ChannelDigestWindow.morning(now: now(), calendar: calendar(), minutes: minutes,
                                                       lastRun: defaults.object(forKey: Self.lastRunKey) as? Date,
                                                       coveredThrough: defaults.object(forKey: coverageKey) as? Date) else { return }
        isRunning = true
        defer { isRunning = false }
        guard await host.authorized() else { return }
        do {
            let content = try await host.build(window)
            // Settings or the server may have changed while history or the model was running.
            guard !Task.isCancelled, host.server() == server,
                  defaults.object(forKey: Self.enabledKey) as? Bool != false,
                  defaults.bool(forKey: "notificationsEnabled"),
                  ChannelDigestWindow.morning(now: now(), calendar: calendar(),
                                              minutes: defaults.object(forKey: Self.timeKey) as? Int ?? 480,
                                              lastRun: defaults.object(forKey: Self.lastRunKey) as? Date,
                                              coveredThrough: nil) != nil else { return }
            if !content.lines.isEmpty {
                let day = calendar().startOfDay(for: window.through).timeIntervalSince1970
                try await host.deliver(content, server, "morningDigest.\(Int(day))")
            }
            defaults.set(window.through, forKey: Self.lastRunKey)
            defaults.set(window.through, forKey: coverageKey)
            error = nil
        } catch {
            self.error = "Couldn't deliver the morning digest: \(error.localizedDescription)"
        }
    }

    /// The test bundle has an explicit button, never an automatic notification or permission prompt.
    func sendTest() async {
        guard testAllowed, Self.canTest(bundleID: Bundle.main.bundleIdentifier, options: nil, server: host.server()),
              !isRunning else { return }
        let server = host.server()
        isRunning = true
        defer { isRunning = false }
        guard await host.authorized() else {
            error = "Allow notifications for Toy Box Test in System Settings first."
            return
        }
        do {
            guard host.server() == server else { return }
            let date = now()
            let content = try await host.build(ChannelDigestWindow(since: date.addingTimeInterval(-86_400), through: date))
            guard host.server() == server else { return }
            guard !content.lines.isEmpty else {
                error = "The test server has no activity from agents in the last 24 hours."
                return
            }
            try await host.deliver(content, server, "morningDigest.test")
            error = nil
        } catch {
            self.error = "Couldn't deliver the test digest: \(error.localizedDescription)"
        }
    }

    static func canTest(bundleID: String?, options: LaunchOptions?, server: String) -> Bool {
        guard bundleID == "dev.toybox.desktop.test",
              options?.isSnapshot != true, options?.benchmark == nil, options?.resizeBenchmark == nil,
              let url = URL(string: server), ["127.0.0.1", "localhost", "::1"].contains(url.host),
              url.port != 3100 else { return false }
        return true
    }
}

extension MorningDigest {
    static func line(_ state: ChannelState, summary: CatchUp? = nil) -> Content.Line? {
        let count = channelAgentMessageCount(state.messages)
        guard count > 0 else { return nil }
        let text = summary?.needsYou?.text ?? summary?.changes.first?.text
            ?? "\(count) new \(count == 1 ? "message" : "messages")"
        return .init(channelID: state.channel.id, name: state.channel.name, count: count,
                     text: text.replacing(/\s+/, with: " "))
    }

    static func ordered(_ lines: [Content.Line]) -> Content {
        Content(lines: lines.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.channelID < $1.channelID
        })
    }

    static func build(api: ChannelAPI, window: ChannelDigestWindow, summarizes: Bool,
                      intelligence: any ChannelIntelligenceService) async throws -> Content {
        let channels = try await api.catalog().channels
        var lines: [Content.Line] = []
        for channel in channels where channel.latestSequence > 0 {
            try Task.checkCancellation()
            if let updated = ChannelDates.date(channel.updatedAt), updated <= window.since { continue }
            var snapshot: ChannelState?
            for try await event in api.observe(channelId: channel.id) {
                guard event.type == "snapshot", let state = event.state else {
                    throw ChannelAPIError.invalidEvent("snapshot")
                }
                snapshot = state
                break
            }
            guard let snapshot else { throw ChannelAPIError.streamEnded }
            let state = try await window.history(snapshot) {
                try await api.history(channelId: channel.id, before: $0).messages
            }
            guard line(state) != nil else { continue }
            var summary: CatchUp?
            if summarizes, intelligence.availability.isAvailable,
               let request = CatchUpRequest(server: api.baseURL, state: state,
                                            unreadAfter: (state.messages.first?.sequence ?? 1) - 1,
                                            scope: .dailyDigest) {
                summary = await withTaskGroup(of: CatchUp?.self) { group in
                    group.addTask { await intelligence.catchUp(request).catchUp }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(15))
                        return nil
                    }
                    let result = await group.next() ?? nil
                    group.cancelAll()
                    return result
                }
            }
            if let line = line(state, summary: summary) { lines.append(line) }
        }
        return ordered(lines)
    }
}
