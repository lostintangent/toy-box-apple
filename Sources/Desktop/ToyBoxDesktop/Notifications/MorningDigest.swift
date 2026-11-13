import AppKit
import ChannelClient
import ChannelIntelligence
import ChannelKit
import Observation

/// A once-per-morning recap of every server. Reading history here never changes a channel's store or
/// read receipt.
@MainActor @Observable
final class MorningDigest {
    nonisolated static let enabledKey = "morningDigestEnabled"
    nonisolated static let timeKey = "morningDigestMinutes"
    nonisolated static let lastRunKey = "morningDigestLastRun"
    nonisolated static let category = "morningDigest"

    struct Content: Equatable {
        struct Line: Equatable {
            /// Its server, as the app saved it.
            var serverURL: String
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
        /// Every saved server, in Settings order.
        var servers: () -> [String]
        var authorized: () async -> Bool
        /// One server's lines.
        var build: (String, ChannelDigestWindow) async throws -> Content
        /// The digest and its notification's identifier.
        var deliver: (Content, String) async throws -> Void
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

    /// Delivers one digest across every server once it's due. A server that fails is left out and
    /// covered from where it left off the next morning, and only when every one fails does it try
    /// again.
    func check() async {
        guard allowed, !isRunning,
              defaults.object(forKey: Self.enabledKey) as? Bool != false,
              defaults.bool(forKey: "notificationsEnabled") else { return }
        let servers = host.servers()
        let date = now()
        var windows: [(server: String, window: ChannelDigestWindow)] = []
        for server in servers {
            guard let window = window(at: date, coveredThrough: defaults.object(forKey: Self.coverageKey(server)) as? Date)
            else { return }
            windows.append((server, window))
        }
        guard !windows.isEmpty else { return }
        isRunning = true
        defer { isRunning = false }
        guard await host.authorized() else { return }
        do {
            var lines: [Content.Line] = []
            var covered: [String] = []
            var failure: (any Error)?
            for (server, window) in windows {
                do {
                    lines += try await host.build(server, window).lines
                    covered.append(server)
                } catch {
                    failure = error
                }
            }
            if covered.isEmpty, let failure { throw failure }
            // Settings or the servers may have changed while history or the model was running.
            guard !Task.isCancelled, host.servers() == servers,
                  defaults.object(forKey: Self.enabledKey) as? Bool != false,
                  defaults.bool(forKey: "notificationsEnabled"),
                  window(at: now(), coveredThrough: nil) != nil else { return }
            let content = Self.ordered(lines)
            if !content.lines.isEmpty {
                let day = calendar().startOfDay(for: date).timeIntervalSince1970
                try await host.deliver(content, "morningDigest.\(Int(day))")
            }
            defaults.set(date, forKey: Self.lastRunKey)
            for server in covered { defaults.set(date, forKey: Self.coverageKey(server)) }
            error = nil
        } catch {
            self.error = "Couldn't deliver the morning digest: \(error.localizedDescription)"
        }
    }

    private func window(at date: Date, coveredThrough: Date?) -> ChannelDigestWindow? {
        ChannelDigestWindow.morning(now: date, calendar: calendar(),
                                    minutes: defaults.object(forKey: Self.timeKey) as? Int ?? 480,
                                    lastRun: defaults.object(forKey: Self.lastRunKey) as? Date,
                                    coveredThrough: coveredThrough)
    }

    /// How far a server's digests have covered.
    static func coverageKey(_ server: String) -> String { "morningDigestThrough.\(server)" }

    /// The test bundle has an explicit button, never an automatic notification or permission prompt.
    func sendTest() async {
        let servers = host.servers()
        let testable = servers.filter { Self.canTest(bundleID: Bundle.main.bundleIdentifier, options: nil, server: $0) }
        guard testAllowed, !testable.isEmpty, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        guard await host.authorized() else {
            error = "Allow notifications for Toy Box Test in System Settings first."
            return
        }
        do {
            guard host.servers() == servers else { return }
            let date = now()
            var lines: [Content.Line] = []
            for server in testable {
                lines += try await host.build(server, ChannelDigestWindow(since: date.addingTimeInterval(-86_400),
                                                                          through: date)).lines
            }
            guard host.servers() == servers else { return }
            let content = Self.ordered(lines)
            guard !content.lines.isEmpty else {
                error = "The test servers have no activity from agents in the last 24 hours."
                return
            }
            try await host.deliver(content, "morningDigest.test")
            error = nil
        } catch {
            self.error = "Couldn't deliver the test digest: \(error.localizedDescription)"
        }
    }

    static func canTest(bundleID: String?, options: LaunchOptions?, server: String) -> Bool {
        guard bundleID == "dev.toybox.desktop.test",
              options?.isSnapshot != true, options?.benchmark == nil,
              let url = URL(string: server), ["127.0.0.1", "localhost", "::1"].contains(url.host),
              url.port != 3100 else { return false }
        return true
    }
}

extension MorningDigest {
    static func line(_ state: ChannelState, serverURL: String, summary: CatchUp? = nil) -> Content.Line? {
        let count = state.messages.agentMessageCount()
        guard count > 0 else { return nil }
        let text = summary?.needsYou?.text ?? summary?.changes.first?.text
            ?? "\(count) new \(count == 1 ? "message" : "messages")"
        return .init(serverURL: serverURL, channelID: state.channel.id, name: state.channel.name, count: count,
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
            if let updated = try? Date(channel.updatedAt, strategy: .iso8601), updated <= window.since { continue }
            var snapshot: ChannelState?
            for try await event in api.subscribe(channelId: channel.id) {
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
            guard line(state, serverURL: api.baseURL.absoluteString) != nil else { continue }
            var summary: CatchUp?
            if summarizes, intelligence.availability.isAvailable,
               let request = CatchUpRequest(server: api.baseURL, state: state,
                                            unreadAfter: (state.messages.first?.sequence ?? 1) - 1,
                                            scope: .dailyDigest) {
                summary = await intelligence.catchUp(request, within: .seconds(15))
            }
            if let line = line(state, serverURL: api.baseURL.absoluteString, summary: summary) { lines.append(line) }
        }
        return ordered(lines)
    }
}
