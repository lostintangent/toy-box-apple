import AppKit
import ChannelKit
import ChannelClient
import SwiftUI
import Synchronization
import Testing
@testable import ToyBoxChannels

@Suite("Shell launch configuration")
struct ShellTests {
    @Test func ordinaryLaunchKeepsNativeDefaults() throws {
        let options = try LaunchOptions.parse([])
        #expect(options.serverURL == nil)
        #expect(options.channelID == nil)
        #expect(options.appearance == nil)
        #expect(options.width == 1280)
        #expect(options.height == 840)
        #expect(!options.isSnapshot)
    }

    @Test func snapshotParsesEveryRequestedSurface() throws {
        let options = try LaunchOptions.parse([
            "--server", "https://example.test/toy-box",
            "--channel", "studio-demo", "--appearance", "dark",
            "--size", "760x560", "--snapshot", "/tmp/shell-test.png", "--state", "inspector"
        ])
        #expect(options.serverURL == "https://example.test/toy-box")
        #expect(options.channelID == "studio-demo")
        #expect(options.appearance == .dark)
        #expect(options.width == 760)
        #expect(options.height == 560)
        #expect(options.snapshotURL?.path == "/tmp/shell-test.png")
        #expect(options.snapshotState == "inspector")
        #expect(options.isSnapshot)
    }

    @Test(arguments: [
        ["--snapshot", "/tmp/test.png"],
        ["--channel", ""],
        ["--channel"],
        ["--channel", "--appearance", "light"],
        ["--appearance", "system"],
        ["--appearance", "sepia"],
        ["--size", "759x560"],
        ["--size", "760x559"],
        ["--size", "4097x840"],
        ["--size", "1280x840x1"],
        ["--size", "nanx840"],
        ["--snapshot", "/tmp/test.jpg"],
        ["--state", "inspector"],
        ["--channel", "one", "--channel", "two"],
        ["--unknown", "value"],
        ["--benchmark-resize", "width"],
        ["--channel", "studio-demo", "--benchmark-resize", "height"],
        ["--channel", "studio-demo", "--benchmark-resize", "width", "--snapshot", "/tmp/test.png"]
    ])
    func malformedArgumentsFailExplicitly(_ arguments: [String]) {
        #expect(throws: LaunchArgumentError.self) { try LaunchOptions.parse(arguments) }
    }

    @Test func resizeBenchmarkNamesItsAxisAndChannel() throws {
        let width = try LaunchOptions.parse(["--channel", "studio-demo", "--benchmark-resize", "width"])
        #expect(width.resizeBenchmark == .width)
        #expect(!width.isSnapshot)
        let both = try LaunchOptions.parse(["--channel", "studio-demo", "--benchmark-resize", "both"])
        #expect(both.resizeBenchmark == .both)
        #expect(try LaunchOptions.parse(["--channel", "studio-demo"]).resizeBenchmark == nil)
    }

    /// A round drags out to the widest size and back, one size per display frame.
    @MainActor @Test func resizeBenchmarkRoundsReturnToTheirStart() {
        let width = ResizeBenchmark.sizes(axis: .width)
        #expect(width.count == ResizeBenchmark.stepsPerRound)
        #expect(width.first == CGSize(width: 1040, height: 700))
        #expect(width.allSatisfy { $0.height == 700 })
        #expect(width.map(\.width).max() == CGFloat(1040 + 60 * 8))
        let both = ResizeBenchmark.sizes(axis: .both)
        #expect(both.map(\.height).max() == CGFloat(700 + 60 * 4))
        #expect(both.last == CGSize(width: 1048, height: 704))
    }

    @Test func appKitLaunchPreferencesDoNotBecomeAppArguments() throws {
        let options = try LaunchOptions.parse(["-NSDocumentRevisionsDebugMode", "YES",
                                               "--channel", "studio-demo", "-ApplePersistenceIgnoreState", "YES"])
        #expect(options.channelID == "studio-demo")
    }

    @Test func eachNewWindowHasAnIndependentIdentity() {
        let first = ChannelWindowValue(channelID: "studio-demo")
        let second = ChannelWindowValue(channelID: "studio-demo")
        #expect(first.channelID == second.channelID)
        #expect(first != second)
    }

    @MainActor @Test(arguments: [1, 2])
    func attachedSheetCompositePreservesScaleAndPosition(_ scale: Int) throws {
        func bitmap(width: Int, height: Int, components: [CGFloat]) throws -> NSBitmapImageRep {
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColorSpace(space)
            context.setFillColor(components)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        }
        let base = try bitmap(width: 100 * scale, height: 80 * scale,
                              components: [1, 0, 0, 1])
        let sheet = try bitmap(width: 20 * scale, height: 10 * scale,
                               components: [0, 0, 1, 1])
        let result = try WindowSnapshot.composite(
            sheet, in: NSRect(x: 10, y: 20, width: 20, height: 10),
            onto: base, logicalSize: NSSize(width: 100, height: 80)
        )
        #expect(result.pixelsWide == 100 * scale)
        #expect(result.pixelsHigh == 80 * scale)
        let inside = try #require(result.colorAt(x: 20 * scale, y: 55 * scale)?.usingColorSpace(.sRGB))
        let outside = try #require(result.colorAt(x: 2 * scale, y: 2 * scale)?.usingColorSpace(.sRGB))
        let expectedInside = try #require(sheet.colorAt(x: 10 * scale, y: 5 * scale)?.usingColorSpace(.sRGB))
        let expectedOutside = try #require(base.colorAt(x: 2 * scale, y: 2 * scale)?.usingColorSpace(.sRGB))
        #expect(abs(inside.redComponent - expectedInside.redComponent) < 0.01)
        #expect(abs(inside.greenComponent - expectedInside.greenComponent) < 0.01)
        #expect(abs(inside.blueComponent - expectedInside.blueComponent) < 0.01)
        #expect(abs(outside.redComponent - expectedOutside.redComponent) < 0.01)
        #expect(abs(outside.greenComponent - expectedOutside.greenComponent) < 0.01)
        #expect(abs(outside.blueComponent - expectedOutside.blueComponent) < 0.01)
        #expect(result.representation(using: .png, properties: [:]) != nil)
    }

    @MainActor @Test func notificationBaselineAndMilestonesAreDeduplicated() {
        var policy = ChannelNotifications.Policy()
        var channel = testChannel()
        channel.requestSequence = 10
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true).isEmpty)
        channel.requestSequence = 11
        channel.latestSequence = 11
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true)
            == [.init(channel: channel, sequence: 11, kind: .request)])
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true).isEmpty)
        channel.latestSequence = 12
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true).isEmpty)
    }

    @MainActor @Test(arguments: ["active", "disabled", "requests-off"])
    func suppressedNotificationsDoNotBackfillWhenEnabled(_ reason: String) {
        var policy = ChannelNotifications.Policy()
        var channel = testChannel()
        _ = policy.events(channels: [channel], activeChannelID: nil, enabled: true)
        channel.requestSequence = 10
        #expect(policy.events(channels: [channel],
                              activeChannelID: reason == "active" ? channel.id : nil,
                              enabled: reason != "disabled", requests: reason != "requests-off").isEmpty)
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true).isEmpty)
        channel.requestSequence = 11
        channel.latestSequence = 11
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true).count == 1)
    }

    @MainActor @Test func completionNotificationsRequireANewUnseenMilestone() {
        var policy = ChannelNotifications.Policy()
        var channel = testChannel()
        _ = policy.events(channels: [channel], activeChannelID: nil, enabled: true)
        channel.seenThrough = 10
        channel.completedSequence = 10
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true).isEmpty)
        channel.completedSequence = 11
        channel.latestSequence = 11
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true)
            == [.init(channel: channel, sequence: 11, kind: .completion)])
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true).isEmpty)
        channel.completedSequence = 12
        channel.latestSequence = 12
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true, completions: false).isEmpty)
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true).isEmpty)
        policy = ChannelNotifications.Policy()
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true).isEmpty)
    }

    @MainActor @Test func dockCountsChannelsAndKeepsOpenRequestsVisible() {
        var request = testChannel(id: "request")
        request.requestSequence = 20
        request.latestSequence = 20
        var finished = testChannel(id: "finished")
        finished.completedSequence = 10
        finished.seenThrough = 9
        var unread = testChannel(id: "unread")
        unread.latestSequence = 100
        let channels = [request, finished, unread, testChannel(id: "quiet")]
        #expect(AppModel.dockBadge(channels: channels, openChannelIDs: []) == "3")
        #expect(AppModel.dockBadge(channels: channels, openChannelIDs: ["request", "finished", "unread"]) == "1")
        #expect(AppModel.dockBadge(channels: [finished, unread], openChannelIDs: ["finished", "unread"]) == nil)
        #expect(AppModel.dockBadge(channels: [], openChannelIDs: []) == nil)
    }

    @MainActor @Test(arguments: [0, 1, 2])
    func connectionSummaryPluralizesChannelCount(_ count: Int) {
        let quantities = ["0 channels", "1 channel", "2 channels"]
        #expect(SettingsView.connectionSummary(serverURL: "https://example.test", channelCount: count)
                == "Connected to https://example.test. \(quantities[count]) available.")
    }

    @MainActor @Test(arguments: [false, true], [false, true])
    func fallbackAvatarInkMeetsTextContrast(isDark: Bool, invalidMark: Bool) throws {
        let avatar = invalidMark ? AgentAvatar(mark: "!", color: "#0891b2") : nil
        let agent = ChannelAgent(id: "fallback", name: "Ada", avatar: avatar)
        let surface = isDark ? Color(red: 0.12, green: 0.12, blue: 0.12) : Color.white
        let renderer = ImageRenderer(content: AgentAvatarView(agent: agent, size: 64)
            .padding(8).background(surface).environment(\.colorScheme, isDark ? .dark : .light))
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        func luminance(x: Int, y: Int) throws -> Double {
            let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            func linear(_ value: CGFloat) -> Double {
                let component = Double(value)
                return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
                + 0.0722 * linear(color.blueComponent)
        }
        let field = try luminance(x: 80, y: 32)
        var inkContrast = 1.0
        for y in 48..<112 {
            for x in 48..<112 {
                let ink = try luminance(x: x, y: y)
                inkContrast = max(inkContrast, (max(ink, field) + 0.05) / (min(ink, field) + 0.05))
            }
        }
        #expect(inkContrast >= 4.5)
    }

    @MainActor @Test(arguments: [false, true])
    func sidebarAvatarsRepresentOnlyWorkingAgents(_ isWorking: Bool) async throws {
        let agent = ChannelAgent(id: "active", name: "Ada",
                                 avatar: .init(mark: "M4 12H20", color: "#ff00ff"))
        let view = NSHostingView(rootView:
            ChannelSidebarRow(channel: testChannel(), agents: [agent],
                              working: isWorking ? [agent] : [], attention: nil,
                              folder: nil, openFolder: {}, onTap: {})
                .frame(width: 240, height: 80)
                .background(Color.white)
                .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var avatarPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.redComponent - color.greenComponent > 0.3
                    && color.blueComponent - color.greenComponent > 0.3 {
                    avatarPixels += 1
                }
            }
        }
        #expect(isWorking ? avatarPixels > 100 : avatarPixels == 0,
                "Working: \(isWorking), avatar pixels: \(avatarPixels), size: \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }

    @Test func lastActivityFollowsMailDayBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 30)))
        func ago(days: Int, hour: Int) throws -> Date {
            let day = try #require(calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)))
            return try #require(calendar.date(byAdding: .hour, value: hour, to: day))
        }
        let cases: [(Date, ChannelActivityTime.Day)] = [
            (try ago(days: 0, hour: 0), .today),
            (now.addingTimeInterval(3600), .today),
            (try ago(days: 1, hour: 23), .yesterday),
            (try ago(days: 1, hour: 0), .yesterday),
            (try ago(days: 2, hour: 12), .weekday),
            (try ago(days: 6, hour: 0), .weekday),
            (try ago(days: 7, hour: 23), .older),
            (try ago(days: 400, hour: 9), .older),
        ]
        for (date, expected) in cases {
            #expect(ChannelActivityTime.day(of: date, now: now, calendar: calendar) == expected, "\(date)")
        }
        let yesterday = try ago(days: 1, hour: 9)
        #expect(ChannelActivityTime.label(for: yesterday, now: now, calendar: calendar) == "Yesterday")
        #expect(ChannelActivityTime.accessibilityLabel(for: now, now: now, calendar: calendar)
                .hasPrefix("Last activity today at "))
    }

    @Test(arguments: [
        ("http://localhost:3100", true), ("http://toy.localhost:3100", true),
        ("http://127.0.0.1:3210", true), ("http://[::1]:3100", true),
        ("https://example.com", false), ("http://192.168.1.20:3100", false),
    ])
    func loopbackServersAreThisMac(_ server: String, _ isLoopback: Bool) throws {
        let url = try #require(URL(string: server))
        #expect(ChannelFolders.isLoopback(ChannelFolders.normalizedHost(url)) == isLoopback)
    }

    @MainActor @Test func folderAvailabilityIsCachedUntilRefresh() throws {
        let folders = ChannelFolders()
        let local = try #require(URL(string: "http://127.0.0.1:3210"))
        let remote = try #require(URL(string: "https://toybox.example.com"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbm-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        try Data().write(to: file)

        #expect(folders.availability(path: directory.path, server: local) == .openable)
        #expect(folders.availability(path: file.path, server: local) == .missing)
        #expect(folders.availability(path: directory.path + "-gone", server: local) == .missing)
        #expect(folders.availability(path: directory.path, server: remote) == .remote(host: "toybox.example.com"))

        try FileManager.default.removeItem(at: directory)
        #expect(folders.availability(path: directory.path, server: local) == .openable)
        folders.refresh(paths: [], server: local)
        #expect(folders.availability(path: directory.path, server: local) == .missing)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        folders.refresh(paths: [directory.path], server: local)
        #expect(folders.availability(path: directory.path, server: local) == .openable)
    }

    private func testChannel(id: String = "test") -> Channel {
        Channel(id: id, name: "Test", model: .init(provider: "test", name: "test"),
                latestSequence: 10, seenThrough: 10,
                updatedAt: "2026-10-22T08:00:00Z")
    }
}

@MainActor
@Suite("Sidebar faces yield")
struct SidebarFacesYieldTests {
    @Test(arguments: [(0, [Int]()), (1, [1]), (2, [2]), (3, [3, 1]), (4, [3, 2, 1]), (5, [3, 2, 1])])
    func smallerStacksAreOfferedOnlyWhenTheCountStandsForTwo(working: Int, limits: [Int]) {
        #expect(ChannelSidebarRow.faceLimits(working: working) == limits)
    }

    /// A real row's second line: how many faces it draws, told apart by their red, green and blue
    /// fills, and where the gray detail text ends before the stack, in points.
    private func secondLine(width: CGFloat, directory: String? = nil, purpose: String? = nil,
                            working count: Int, attention: ChannelAttention? = .unread)
        async throws -> (faces: Int, detailEnd: CGFloat) {
        let agents = stackTestAgents(Array(["#ff0000", "#00ff00", "#0000ff", "#808080", "#808080"].prefix(count)))
        let channel = Channel(id: "yield", name: "Yield", purpose: purpose, directory: directory,
                              model: .init(provider: "test", name: "test"), updatedAt: "2026-10-22T08:00:00Z")
        let view = NSHostingView(rootView:
            ChannelSidebarRow(channel: channel, agents: agents, working: agents, attention: attention,
                              folder: directory == nil ? nil : .remote(host: "elsewhere"),
                              openFolder: {}, onTap: {})
                .frame(width: width, height: 60)
                .background(Color.white)
                .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var pixels: [[(CGFloat, CGFloat, CGFloat)]] = []
        for y in 0..<bitmap.pixelsHigh {
            pixels.append(try (0..<bitmap.pixelsWide).map { x in
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                return (color.redComponent, color.greenComponent, color.blueComponent)
            })
        }
        var counts = [0, 0, 0]
        var stackStart = bitmap.pixelsWide
        var top = Int.max, bottom = -1
        for (y, row) in pixels.enumerated() {
            for (x, pixel) in row.enumerated() {
                let rgb = [pixel.0, pixel.1, pixel.2]
                for channel in 0..<3 where rgb[channel] - rgb[(channel + 1) % 3] > 0.35
                    && rgb[channel] - rgb[(channel + 2) % 3] > 0.35 {
                    counts[channel] += 1
                    stackStart = min(stackStart, x)
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
            }
        }
        var detailEnd = 0
        for y in pixels.indices where y >= top && y <= bottom {
            for x in 0..<stackStart {
                let (red, green, blue) = pixels[y][x]
                if max(red, green, blue) < 0.8 && max(red, green, blue) - min(red, green, blue) < 0.08 {
                    detailEnd = max(detailEnd, x + 1)
                }
            }
        }
        // A partly covered face is about 120 square points. The 7-point unread dot is under 40.
        let scale = CGFloat(bitmap.pixelsWide) / width
        return (counts.filter { CGFloat($0) > 60 * scale * scale }.count, CGFloat(detailEnd) / scale)
    }

    // Text starts after 8 points of padding, the 30-point icon and 10 points.
    private let textStart: CGFloat = 48

    @Test func aFolderKeepsItsWholeNameWhileTheStackGivesUpFaces() async throws {
        let whole = try await secondLine(width: 320, directory: "/tmp/toy-box-mac", working: 5)
        #expect(whole.faces == 3)
        for (width, faces) in [(CGFloat(236), 3), (223, 2), (211, 1)] {
            let line = try await secondLine(width: width, directory: "/tmp/toy-box-mac", working: 5)
            #expect(line.faces == faces, "At \(width)")
            #expect(line.detailEnd == whole.detailEnd, "The folder truncated at \(width)")
        }
        // Only the last resort truncates the folder, and the stack keeps its full width there.
        let squeezed = try await secondLine(width: 198, directory: "/tmp/toy-box-mac", working: 5)
        #expect(squeezed.faces == 1 && squeezed.detailEnd < whole.detailEnd)
    }

    @Test func stacksNeverTradeAFaceForPlusOne() async throws {
        let folder = "/tmp/a-much-longer-folder-name"
        let whole = try await secondLine(width: 400, directory: folder, working: 3)
        let narrow = try await secondLine(width: 290, directory: folder, working: 3)
        #expect(narrow.faces == 1 && narrow.detailEnd == whole.detailEnd)
        #expect(try await secondLine(width: 310, directory: folder, working: 3).faces == 3)
        #expect(try await secondLine(width: 180, directory: folder, working: 2).faces == 2)
    }

    @Test func purposeRowsYieldFacesOnlyToKeepAReadableStem() async throws {
        let purpose = "Build a welcoming native Mac client"
        #expect(try await secondLine(width: 320, purpose: purpose, working: 4).faces == 3)
        let stem = try await secondLine(width: 188, purpose: purpose, working: 4)
        #expect(stem.faces == 1 && stem.detailEnd - textStart >= 55)
        let squeezed = try await secondLine(width: 174, purpose: purpose, working: 4)
        #expect(squeezed.faces == 1 && squeezed.detailEnd < stem.detailEnd)
    }
}

@MainActor
@Suite("Sidebar connection footer")
struct SidebarConnectionFooterTests {
    @Test(arguments: [
        (false, false, false, SidebarConnection.connecting),
        (true, false, false, .connected),
        (true, true, false, .reconnecting),
        (false, true, false, .unreachable),
        (true, true, true, .unreachable),
        (false, false, true, .unreachable),
    ])
    func theDotFollowsTheCatalog(loaded: Bool, failing: Bool, fatal: Bool, state: SidebarConnection) {
        #expect(SidebarConnection(loaded: loaded, failing: failing, fatal: fatal) == state)
    }

    @Test func everyStateButConnectedNamesItselfAboveTheDot() {
        #expect(SidebarConnection.connected.heading == nil)
        #expect(SidebarConnection.reconnecting.heading == "Channels may be out of date")
        #expect(SidebarConnection.unreachable.heading == "Can't connect to Toy Box")
        #expect([SidebarConnection.connecting, .connected, .reconnecting, .unreachable].map(\.accessibilityValue)
            == ["connecting", "connected", "reconnecting", "can't connect"])
    }

    @Test(arguments: [
        ("http://localhost:3100", "localhost:3100"),
        ("http://127.0.0.1:3213/", "127.0.0.1:3213"),
        ("http://toybox.example:80", "toybox.example"),
        ("https://toybox.example:443/channels", "toybox.example"),
        ("https://toybox.example:80", "toybox.example:80"),
        ("https://toybox.example", "toybox.example"),
        ("http://[::1]:3100", "[::1]:3100"),
        ("not a server", "not a server"),
    ])
    func serverShowsTheHostAndOnlyAnUnusualPort(url: String, shown: String) {
        #expect(SidebarConnection.server(url) == shown)
    }

    @Test func onlyARefusedAuthorizationIsFatal() {
        #expect(SidebarConnection.isFatal(ChannelAPIError.http(status: 401, message: "Unauthorized")))
        #expect(SidebarConnection.isFatal(ChannelAPIError.http(status: 403, message: "Forbidden")))
        #expect(!SidebarConnection.isFatal(ChannelAPIError.http(status: 502, message: "Bad Gateway")))
        #expect(!SidebarConnection.isFatal(URLError(.cannotConnectToHost)))
        #expect(!SidebarConnection.isFatal(nil))
    }

    private let footerSize = CGSize(width: 260, height: 220)

    private func hostFooter(_ connection: SidebarConnection, error: String? = nil, busy: Bool = false,
                            spinning: Bool? = nil) -> NSWindow {
        let content: AnyView = if let spinning {
            AnyView(SidebarStatusLine(connection: connection, spinning: spinning, serverURL: "http://localhost:3100")
                .padding(.leading, SidebarConnectionFooter.leading - SidebarConnectionFooter.capsuleOutset)
                .padding(.bottom, 13))
        } else {
            // A delay no test outlasts, so a busy footer here is one whose attempt hasn't run long.
            AnyView(SidebarConnectionFooter(connection: connection, busy: busy, serverURL: "http://localhost:3100",
                                            error: error, retry: {}, openSettings: {}, spinnerDelay: .seconds(600)))
        }
        let view = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                content
            }
            .frame(width: footerSize.width, height: footerSize.height, alignment: .leading)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: footerSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return window
    }

    /// The center of the footer's dot, found by its color, in points from the leading edge and
    /// from the bottom edge, where the host's gray ink ends on the status line, and the capture's
    /// pixels per point.
    private func sample(_ window: NSWindow, dominant channel: Int) throws
        -> (dot: CGPoint?, textEnd: CGFloat, scale: CGFloat) {
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / footerSize.width
        var sum = CGPoint.zero, count: CGFloat = 0, textEnd = 0
        for y in 0..<bitmap.pixelsHigh {
            let fromBottom = footerSize.height - (CGFloat(y) + 0.5) / scale
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
                if abs(fromBottom - 24) < 7, rgb.max()! < 0.8, rgb.max()! - rgb.min()! < 0.08 {
                    textEnd = max(textEnd, x + 1)
                }
                guard rgb[channel] - rgb[(channel + 1) % 3] > 0.2, rgb[channel] - rgb[(channel + 2) % 3] > 0.2
                else { continue }
                sum.x += CGFloat(x) + 0.5
                sum.y += CGFloat(y) + 0.5
                count += 1
            }
        }
        let dot = count > 3 * scale * scale
            ? CGPoint(x: sum.x / count / scale, y: footerSize.height - sum.y / count / scale) : nil
        return (dot, CGFloat(textEnd) / scale, scale)
    }

    @Test func theDotSharesTheIconEdgeAndClearsTheCornerEvenly() async throws {
        let healthy = hostFooter(.connected)
        defer { healthy.close() }
        try await Task.sleep(for: .milliseconds(100))
        let capture = try sample(healthy, dominant: 1)
        let connected = try #require(capture.dot)
        // An odd-sized dot centered on a whole point lands half a point off at 1x, so the absolute
        // position allows one physical pixel.
        let pixel = 1 / capture.scale
        #expect(abs(connected.x - (SidebarConnectionFooter.leading + 3.5)) <= pixel)
        #expect(abs(connected.y - 24) <= pixel, "Dot at \(connected) at \(capture.scale)x")
        // The error block grows the footer upward, so the dot never moves.
        let broken = hostFooter(.unreachable, error: "Could not connect to the server.")
        defer { broken.close() }
        try await Task.sleep(for: .milliseconds(100))
        let failing = try #require(try sample(broken, dominant: 0).dot)
        #expect(abs(failing.x - connected.x) < 0.5 && abs(failing.y - connected.y) < 0.5)
    }

    @Test func aSlowAttemptSwapsTheDotForASpinnerWithoutMovingTheHost() async throws {
        let quick = hostFooter(.reconnecting, error: "Could not connect to the server.", busy: true)
        defer { quick.close() }
        let resting = hostFooter(.reconnecting, spinning: false)
        defer { resting.close() }
        let spinning = hostFooter(.reconnecting, spinning: true)
        defer { spinning.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try sample(quick, dominant: 0).dot != nil, "An attempt shows the spinner before its delay")
        let dot = try sample(resting, dominant: 0)
        let spinner = try sample(spinning, dominant: 0)
        #expect(dot.dot != nil && spinner.dot == nil)
        #expect(dot.textEnd > 60 && spinner.textEnd == dot.textEnd)
    }
}

@MainActor
@Suite("Requested catalog refresh", .timeLimit(.minutes(1)))
struct RequestedCatalogRefreshTests {
    @Test func aRequestJoinsTheRunningPollAndLastsUntilItResolves() async throws {
        let server = HeldCatalogServer()
        defer { server.close() }
        let catalog = ChannelCatalogStore(api: try server.api())
        let requested = RequestedCatalogRefresh()
        let poll = Task { await catalog.refresh() }
        while server.held == 0 { await Task.yield() }
        #expect(catalog.isLoading && !requested.isRunning(for: catalog), "Background polling shows progress")

        let retry = Task { await requested.run(catalog) }
        while !requested.isRunning(for: catalog) { await Task.yield() }
        #expect(!requested.isRunning(for: ChannelCatalogStore(api: try server.api())))

        server.release(status: 503)
        await poll.value
        await retry.value
        #expect(!requested.isRunning(for: catalog))
        #expect(catalog.error != nil)
        #expect(server.requests == 1, "Retry started a second request instead of joining the poll")
    }

    @Test func aRequestWithNothingRunningEndsWithItsOwnAttempt() async throws {
        let server = HeldCatalogServer()
        defer { server.close() }
        let catalog = ChannelCatalogStore(api: try server.api())
        let requested = RequestedCatalogRefresh()
        let retry = Task { await requested.run(catalog) }
        while server.held == 0 { await Task.yield() }
        #expect(requested.isRunning(for: catalog))
        server.release(status: 503)
        await retry.value
        #expect(!requested.isRunning(for: catalog))
        #expect(server.requests == 1)
    }

    /// Holds every catalog request until the test releases it.
    private final class HeldCatalogServer: Sendable {
        let host = "catalog-\(UUID().uuidString.lowercased()).invalid"
        private let session: URLSession

        init() {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HeldCatalogProtocol.self]
            session = URLSession(configuration: configuration)
            HeldCatalogProtocol.hosts.withLock { $0[host] = .init() }
        }

        func api() throws -> ChannelAPI { try ChannelAPI(serverURL: "https://\(host)", session: session) }
        var held: Int { HeldCatalogProtocol.hosts.withLock { $0[host]?.held.count ?? 0 } }
        var requests: Int { HeldCatalogProtocol.hosts.withLock { $0[host]?.requests ?? 0 } }

        func release(status: Int) {
            let held = HeldCatalogProtocol.hosts.withLock { hosts in
                defer { hosts[host]?.held = [] }
                return hosts[host]?.held ?? []
            }
            for request in held { request.respond(status: status) }
        }

        func close() {
            session.invalidateAndCancel()
            HeldCatalogProtocol.hosts.withLock { _ = $0.removeValue(forKey: host) }
        }
    }

    private final class HeldCatalogProtocol: URLProtocol, @unchecked Sendable {
        struct Host: Sendable {
            var held: [HeldCatalogProtocol] = []
            var requests = 0
        }
        static let hosts = Mutex<[String: Host]>([:])

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let host = request.url?.host ?? ""
            let known = Self.hosts.withLock { hosts in
                guard hosts[host] != nil else { return false }
                hosts[host]?.requests += 1
                hosts[host]?.held.append(self)
                return true
            }
            if !known { client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)) }
        }

        func respond(status: Int) {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":"Service Unavailable"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@MainActor
@Suite("Conversation lane")
struct ConversationRailTests {
    /// The spec's hosted geometry at the default text size: the lane is the conversation width less
    /// two 24-point insets, with no maximum, and the composer's leading edge sits on the avatars'.
    @Test(arguments: [(420, 372), (720, 672), (760, 712), (1_000, 952), (1_400, 1_352)] as [(CGFloat, CGFloat)])
    func theComposerSpansTheWholeLaneFromTheAvatarsEdge(width: CGFloat, lane: CGFloat) async throws {
        let frames = RailFrames()
        let view = NSHostingView(rootView:
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 32, height: 20)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.avatar = $0 }
                    Color.clear.frame(height: 20)
                }
                .modifier(ConversationRail())
                Color.clear.frame(height: 20)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.composer = $0 }
                    .modifier(ConversationRail())
            }
            .frame(width: width, height: 40))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()

        let avatar = try #require(frames.avatar)
        let composer = try #require(frames.composer)
        #expect(abs(avatar.minX - ConversationRail.inset) < 0.5)
        #expect(abs(composer.minX - avatar.minX) < 0.5)
        #expect(abs(composer.width - lane) < 0.5)
        #expect(abs(composer.maxX - (width - ConversationRail.inset)) < 0.5)
    }

    @Test func titleMenuBadgesNameTheSidebarsAttention() {
        #expect(ChannelDetailView.badge(.waiting) == Text("Input Needed"))
        #expect(ChannelDetailView.badge(.unread) == Text("Unread"))
        #expect(ChannelDetailView.badge(.finished) == Text("Done"))
        #expect(ChannelDetailView.badge(nil) == nil)
    }
}

@MainActor private final class RailFrames {
    var avatar: CGRect?
    var composer: CGRect?
}

@MainActor
@Suite("Inspector placement")
struct InspectorPlacementTests {
    private final class Clock {
        var date = Date(timeIntervalSinceReferenceDate: 0)
        func advance(_ seconds: TimeInterval) { date += seconds }
    }

    private func placement(_ clock: Clock) -> InspectorPlacement {
        let placement = InspectorPlacement()
        placement.now = { clock.date }
        return placement
    }

    @Test(arguments: [
        (CGFloat(248), CGFloat(312), CGFloat(1000)),
        (320, 312, 1144),
        (0, 312, 1000),
        (248, 372.5, 1060.5),
    ])
    func widthNeededKeepsTheConversationBesideBothColumns(sidebar: CGFloat, inspector: CGFloat, needed: CGFloat) {
        #expect(InspectorPlacement.widthNeeded(sidebar: sidebar, inspector: inspector) == needed)
    }

    @Test func aStillDividerDragIsThePersonsChoice() {
        let placement = placement(Clock())
        #expect(placement.columnChanged(to: true, presented: true) == nil)
        #expect(placement.columnChanged(to: false, presented: true) == false)
        #expect(placement.revision == 0)
    }

    @Test func aCollapseWhileTheWindowMovesIsRestoredThenSetAside() {
        let clock = Clock()
        let placement = placement(clock)
        placement.update(windowWidth: 1280)
        #expect(placement.columnChanged(to: true, presented: false) == nil)
        #expect(placement.revision == 0)

        #expect(placement.columnChanged(to: false, presented: true) == nil)
        #expect(placement.revision == 1)
        #expect(!placement.isNarrow(windowWidth: 1280))

        clock.advance(0.5)
        #expect(placement.columnChanged(to: false, presented: true) == nil)
        #expect(placement.revision == 1)
        #expect(placement.isNarrow(windowWidth: 1280))

        placement.update(windowWidth: 1300)
        #expect(!placement.isNarrow(windowWidth: 1300))
    }

    @Test func aSqueezedInspectorCountsOnlyOnceTheLayoutIsStill() {
        let clock = Clock()
        let placement = placement(clock)
        placement.update(sidebar: 248, inspector: 372.5)
        #expect(placement.widthNeeded == 1060.5)

        placement.update(windowWidth: 1100)
        placement.update(sidebar: nil, inspector: 312)
        #expect(placement.widthNeeded == 1060.5)

        clock.advance(1.2)
        placement.update(sidebar: nil, inspector: 312)
        #expect(placement.widthNeeded == 1000)
        #expect(placement.isNarrow(windowWidth: 990))
    }

    /// A resize reports every frame, and views read only whether Overview is a sheet.
    @Test func theWindowIsNarrowOnlyOnceItReportsAWidthBelowTheColumns() {
        let placement = placement(Clock())
        #expect(placement.isWindowNarrow == nil)
        placement.update(windowWidth: 1100)
        #expect(placement.isWindowNarrow == false)
        placement.update(windowWidth: 999)
        #expect(placement.isWindowNarrow == true)
        placement.update(windowWidth: 1100)
        #expect(placement.isWindowNarrow == false)
        placement.update(sidebar: 320, inspector: nil)
        #expect(placement.isWindowNarrow == true)
    }
}

@MainActor
@Suite("Settled layout")
struct SettledLayoutTests {
    @Test(arguments: [
        (ProposedViewSize(width: 600, height: 400), true),
        (ProposedViewSize(width: 172, height: 560), true),
        (ProposedViewSize(width: 700, height: 52), false),
        (ProposedViewSize(width: 0, height: 0), false),
        (ProposedViewSize(width: 60, height: 560), false),
        (ProposedViewSize(width: nil, height: 560), false),
        (ProposedViewSize(width: 600, height: nil), false),
        (ProposedViewSize(width: .infinity, height: 560), false),
    ])
    func onlySizesAWindowCanShowCount(proposal: ProposedViewSize, shown: Bool) {
        #expect(SettledLayout.isShown(proposal) == shown)
    }

    /// AppKit's split views size their columns at sizes no window shows during each frame of a
    /// resize. The content stays laid out at the last shown size until the next one arrives.
    @Test func temporarySizesLeaveTheContentWhereItWas() {
        let log = SettledLayoutLog()
        let host = NSHostingView(rootView: RecordingLayout(log: log) { Color.clear }.settledLayout())
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.addSubview(host)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        func layout(_ size: CGSize) {
            log.measured = []
            log.placed = []
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
        }

        layout(CGSize(width: 600, height: 400))
        #expect(log.placed.last == CGSize(width: 600, height: 400))

        for transient in [CGSize(width: 452, height: 52), CGSize(width: 0, height: 0), CGSize(width: 948, height: 104)] {
            layout(transient)
            #expect(log.measured.allSatisfy { SettledLayout.isShown(ProposedViewSize($0)) })
            #expect(log.placed.allSatisfy { $0 == CGSize(width: 600, height: 400) })
        }

        layout(CGSize(width: 700, height: 420))
        #expect(log.placed.last == CGSize(width: 700, height: 420))
    }
}

@MainActor private final class SettledLayoutLog {
    var measured: [CGSize] = []
    var placed: [CGSize] = []
}

private struct RecordingLayout: Layout {
    let log: SettledLayoutLog

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = proposal.replacingUnspecifiedDimensions()
        MainActor.assumeIsolated { log.measured.append(size) }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        MainActor.assumeIsolated { log.placed.append(bounds.size) }
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}
