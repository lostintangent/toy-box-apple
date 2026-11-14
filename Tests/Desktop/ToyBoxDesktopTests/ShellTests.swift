import AppKit
import Carbon
import ChannelKit
@testable import ChannelClient
import ChannelIntelligence
import CoreTransferable
import Observation
import SwiftUI
import ToyBoxUI
import Synchronization
import Testing
import UniformTypeIdentifiers
import UserNotifications
@testable import ToyBoxDesktop

@Suite("Quick Send host and shortcut")
@MainActor
final class QuickSendShellTests {
    private let suite = "quick-send-\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    @Test func theDefaultRegistersAndClearingSurvivesTheNextLaunch() throws {
        let hotKey = FakeQuickSendHotKey()
        let controller = QuickSendController(defaults: defaults, hotKey: hotKey)
        #expect(controller.shortcut == .defaultValue)
        #expect(hotKey.registered == .defaultValue)
        #expect(controller.shortcut?.displayName == "⌃⇧Space")
        #expect(controller.shortcut?.keyboardShortcut?.key == .space)
        controller.setShortcut(nil)
        #expect(hotKey.registered == nil)
        #expect(controller.shortcut == nil)
        let next = FakeQuickSendHotKey()
        let relaunched = QuickSendController(defaults: defaults, hotKey: next)
        #expect(relaunched.shortcut == nil)
        #expect(next.calls.isEmpty)
    }

    @Test func recordingSuspendsTheOldShortcutAndPersistsTheNewPhysicalKey() throws {
        let hotKey = FakeQuickSendHotKey()
        let controller = QuickSendController(defaults: defaults, hotKey: hotKey)
        controller.setRecording(true)
        #expect(hotKey.registered == nil)
        let chosen = QuickSendShortcut(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .shift, .capsLock])
        controller.setShortcut(chosen)
        controller.setRecording(false)
        #expect(chosen.modifiers == UInt32(controlKey | shiftKey))
        #expect(hotKey.registered == chosen)
        #expect(controller.error == nil)
        let restored = QuickSendController(defaults: defaults, hotKey: FakeQuickSendHotKey())
        #expect(restored.shortcut == chosen)
    }

    @Test func aConflictPreservesThePreviousPreferenceAndRestoresItsRegistration() {
        let hotKey = FakeQuickSendHotKey()
        let controller = QuickSendController(defaults: defaults, hotKey: hotKey)
        controller.setRecording(true)
        hotKey.rejected = QuickSendShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey))
        controller.setShortcut(hotKey.rejected)
        controller.setRecording(false)
        #expect(controller.shortcut == .defaultValue)
        #expect(hotKey.registered == .defaultValue)
        #expect(controller.error?.contains("already in use") == true)
        #expect(defaults.object(forKey: QuickSendShortcut.preferenceKey) == nil)
    }

    @Test func cancellingRecordingReinstallsTheOriginalWithoutChangingPreferences() {
        let hotKey = FakeQuickSendHotKey()
        let controller = QuickSendController(defaults: defaults, hotKey: hotKey)
        controller.setRecording(true)
        controller.setRecording(false)
        #expect(hotKey.calls == [.defaultValue, nil, .defaultValue])
        #expect(defaults.object(forKey: QuickSendShortcut.preferenceKey) == nil)
    }

    @Test func malformedSavedShortcutsShowAnErrorWithoutTakingAnotherShortcut() throws {
        defaults.set(Data("broken".utf8), forKey: QuickSendShortcut.preferenceKey)
        let hotKey = FakeQuickSendHotKey()
        let controller = QuickSendController(defaults: defaults, hotKey: hotKey)
        #expect(controller.error != nil)
        #expect(controller.shortcut == nil)
        #expect(hotKey.calls.isEmpty)
        controller.setShortcut(.defaultValue)
        #expect(controller.error == nil)
        #expect(hotKey.registered == .defaultValue)
    }

    @Test func typingAndReservedShortcutsAreRejectedBeforeRegistration() {
        let plain = QuickSendShortcut(keyCode: UInt16(kVK_ANSI_A), flags: [])
        let shifted = QuickSendShortcut(keyCode: UInt16(kVK_ANSI_A), flags: [.shift])
        let spotlight = QuickSendShortcut(keyCode: UInt16(kVK_Space), flags: [.command])
        let voiceOver = QuickSendShortcut(keyCode: UInt16(kVK_Space), flags: [.control, .option])
        let escape = QuickSendShortcut(keyCode: UInt16(kVK_Escape), flags: [.control])
        #expect([plain, shifted, spotlight, voiceOver, escape].allSatisfy { $0.validationError != nil })
        #expect(QuickSendShortcut.defaultValue.validationError == nil)
        let hotKey = FakeQuickSendHotKey()
        let controller = QuickSendController(defaults: defaults, hotKey: hotKey)
        controller.setShortcut(plain)
        #expect(controller.shortcut == .defaultValue)
        #expect(hotKey.calls == [.defaultValue])
        #expect(controller.error != nil)
    }

    @Test func snapshotsAndBenchmarksNeverRegisterOrPresent() {
        var snapshot = LaunchOptions()
        snapshot.snapshotURL = URL(fileURLWithPath: "/tmp/quick-send-test.png")
        var benchmark = LaunchOptions()
        benchmark.benchmark = .scroll
        for options in [snapshot, benchmark] {
            let hotKey = FakeQuickSendHotKey()
            let controller = QuickSendController(options: options, defaults: defaults, hotKey: hotKey)
            controller.present()
            controller.setShortcut(nil)
            #expect(!controller.isEnabled)
            #expect(!controller.isPresented)
            #expect(hotKey.calls.isEmpty)
            #expect(defaults.object(forKey: QuickSendShortcut.preferenceKey) == nil)
        }
    }

    @Test func placementUsesThePointersScreenAndKeepsTwentyFourPointEdges() {
        let screen = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        let frame = QuickSendController.frame(size: CGSize(width: 560, height: 220), in: screen)
        #expect(frame.midX == screen.midX)
        #expect(frame.maxY == screen.maxY - screen.height * 0.22)
        #expect(screen.insetBy(dx: 24, dy: 24).contains(frame))
        let small = CGRect(x: 0, y: 0, width: 600, height: 400)
        #expect(small.insetBy(dx: 24, dy: 24).contains(
            QuickSendController.frame(size: CGSize(width: 560, height: 420), in: small)))
    }

    @Test func thePanelExposesAFloatingWindowRatherThanASystemDialog() {
        _ = NSApplication.shared
        let panel = QuickSendPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.accessibilityRole() == .window)
        #expect(panel.accessibilitySubrole() == .floatingWindow)
        #expect(!panel.isVisible)
    }
}

@MainActor
private final class FakeQuickSendHotKey: QuickSendHotKeyRegistering {
    var calls: [QuickSendShortcut?] = []
    var registered: QuickSendShortcut?
    var rejected: QuickSendShortcut?

    func replace(with shortcut: QuickSendShortcut?, onPress: @escaping @MainActor () -> Void) throws {
        if let rejected, shortcut == rejected {
            throw QuickSendHotKeyError(operation: "register", status: OSStatus(eventHotKeyExistsErr))
        }
        calls.append(shortcut)
        registered = shortcut
    }
}

@Suite("Quick Send Services and Dock intake")
@MainActor
struct QuickSendIntakeTests {
    @Test func servicesCopyTextAndURLsWithoutSendingOrClearingTheSource() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let text = NSPasteboardItem()
        text.setString("Selected text", forType: .string)
        let link = NSPasteboardItem()
        link.setString("https://example.test/page", forType: .URL)
        #expect(pasteboard.writeObjects([text, link]))
        var received: [QuickSendPrefill] = []
        let intake = QuickSendIntake { received.append($0) }
        var error: NSString?
        intake.sendToToyBox(pasteboard, userData: nil, error: &error)
        #expect(error == nil)
        #expect(received.count == 1)
        #expect(received.first?.text == "Selected text\n\nhttps://example.test/page")
        #expect(received.first?.fileURLs.isEmpty == true)
        #expect(pasteboard.pasteboardItems?.count == 2)
        #expect(intake.hasReceivedContent)
        #expect(intake.responds(to: NSSelectorFromString("sendToToyBox:userData:error:")))
    }

    @Test func fileRenditionsBecomeFileURLsRatherThanDuplicatePathText() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        let file = URL(fileURLWithPath: "/tmp/selected image.png")
        item.setString(file.absoluteString, forType: .fileURL)
        item.setString(file.path, forType: .string)
        #expect(pasteboard.writeObjects([item]))
        let result = try QuickSendIntake.read(pasteboard)
        #expect(result.fileURLs == [file])
        #expect(result.text.isEmpty)
        #expect(result.images.isEmpty)
    }

    @Test func servicesPreferSupportedImageBytesAndConvertTIFFOnlySelections() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let tiff = try #require(bitmap.representation(using: .tiff, properties: [:]))
        for offersPNG in [false, true] {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let item = NSPasteboardItem()
            item.setData(tiff, forType: .tiff)
            if offersPNG { item.setData(png, forType: .png) }
            #expect(pasteboard.writeObjects([item]))
            let result = try QuickSendIntake.read(pasteboard)
            let image = try #require(result.images.first)
            #expect(image.mimeType == "image/png")
            #expect(image.image != nil)
            if offersPNG { #expect(image.data == png) }
        }
    }

    @Test func emptySelectionsReportAnErrorAndNeverOpenQuickSend() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var count = 0
        let intake = QuickSendIntake { _ in count += 1 }
        var error: NSString?
        intake.sendToToyBox(pasteboard, userData: nil, error: &error)
        #expect(error != nil)
        #expect(count == 0)
        #expect(!intake.hasReceivedContent)
    }

    @Test func dockDropsKeepEveryExplicitFileURLForTheDraftPolicy() throws {
        var received: QuickSendPrefill?
        let intake = QuickSendIntake { received = $0 }
        try intake.openFiles(["/tmp/a.png", "/tmp/a document.pdf"])
        #expect(received?.fileURLs.map(\.path) == ["/tmp/a.png", "/tmp/a document.pdf"])
        #expect(received?.text.isEmpty == true)
    }

    @Test func pendingInvocationsAppendAndAnOldConsumerCannotEraseTheNewerPayload() throws {
        let suite = "quick-send-intake-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var options = LaunchOptions()
        options.snapshotURL = URL(fileURLWithPath: "/tmp/no-window.png")
        let controller = QuickSendController(options: options, defaults: defaults, hotKey: FakeQuickSendHotKey())
        let first = QuickSendPrefill(text: "First", fileURLs: [URL(fileURLWithPath: "/tmp/a.png")])
        controller.present(prefill: first)
        controller.present(prefill: .init(text: "Second", fileURLs: [URL(fileURLWithPath: "/tmp/b.png")]))
        let combined = try #require(controller.pendingPrefill)
        #expect(combined.id != first.id)
        #expect(combined.text == "First\n\nSecond")
        #expect(combined.fileURLs.count == 2)
        controller.consumePrefill(id: first.id)
        #expect(controller.pendingPrefill?.id == combined.id)
        controller.consumePrefill(id: combined.id)
        #expect(controller.pendingPrefill == nil)
        #expect(!controller.isPresented)
    }

    @Test func shareHandoffsAcceptOnlyTheUniquePrivateNamespaceAndClearItAfterCopying() throws {
        let name = "dev.toybox.desktop.share.\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: .init(name))
        pasteboard.setString("Shared selection", forType: .string)
        let url = try #require(URL(string: "toybox-desktop://quick-send?pasteboard=\(name)"))
        #expect(try QuickSendIntake.sharedPasteboardName(in: url) == name)
        var received: QuickSendPrefill?
        try QuickSendIntake { received = $0 }.openSharedURL(url)
        #expect(received?.text == "Shared selection")
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test(arguments: [
        "toybox-desktop://quick-send?pasteboard=NSGeneralPboard",
        "toybox-desktop://quick-send?pasteboard=dev.toybox.desktop.share.not-a-uuid",
        "toybox-desktop://quick-send?pasteboard=",
        "toybox-desktop://quick-send?pasteboard=NSGeneralPboard&pasteboard=other",
        "toybox-desktop://other?pasteboard=NSGeneralPboard",
        "https://quick-send?pasteboard=NSGeneralPboard"
    ])
    func unrelatedPasteboardsAndMalformedRoutesAreRejected(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(throws: QuickSendIntake.IntakeError.self) {
            try QuickSendIntake.sharedPasteboardName(in: url)
        }
    }

    @Test func bundleDeclaresServicesAndDockDropWithoutClaimingDefaultFileHandling() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Desktop/Info.plist"))
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(info["CFBundleName"] as? String == "Toy Box")
        #expect(info["CFBundleDisplayName"] as? String == "Toy Box")
        #expect(info["CFBundleIdentifier"] as? String == "dev.toybox.desktop")
        #expect(info["CFBundleExecutable"] as? String == "ToyBoxDesktop")
        #expect(MenuBarAccessibility.title == "Toy Box")
        let services = try #require(info["NSServices"] as? [[String: Any]])
        #expect(services.first?["NSMessage"] as? String == "sendToToyBox")
        #expect(services.first?["NSPortName"] as? String == "Toy Box")
        let types = try #require(services.first?["NSSendTypes"] as? [String])
        #expect(types.contains("public.utf8-plain-text") && types.contains("public.file-url"))
        let documents = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(documents.allSatisfy { $0["LSHandlerRank"] as? String == "None" })
        let schemes = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        #expect(schemes.first?["CFBundleURLSchemes"] as? [String] == ["toybox-desktop"])
    }
}

@Suite("Shell launch configuration")
struct ShellTests {
    @Test func ordinaryLaunchKeepsNativeDefaults() throws {
        let options = try LaunchOptions.parse([])
        #expect(options.server == nil)
        #expect(options.sessionServer(environment: [:]) == nil, "The app adds no server the user didn't.")
        #expect(options.sessionServer(environment: ["TOY_BOX_SERVER_URL": "http://127.0.0.1:3210"])
                == "http://127.0.0.1:3210")
        #expect(options.channelID == nil)
        #expect(options.appearance == nil)
        #expect(options.width == 1280)
        #expect(options.height == 840)
        #expect(!options.isSnapshot)
    }

    @MainActor @Test(arguments: [
        [], ["--server", "http://127.0.0.1:3210"],
        ["--channel", "studio-demo", "--snapshot", "/tmp/integrations.png"],
        ["--channel", "studio-demo", "--benchmark", "scroll"],
    ], [[:], ["TOY_BOX_SERVER_URL": "http://127.0.0.1:3210"]])
    func userIntegrationsShareLaunchIsolation(_ arguments: [String], _ environment: [String: String]) throws {
        let options = try LaunchOptions.parse(arguments)
        let allowed = arguments.isEmpty && environment.isEmpty
        #expect(options.allowsUserIntegrations(environment: environment) == allowed)
        #expect(OpenAtLogin.isAllowed(options, bundleID: "dev.toybox.desktop", environment: environment) == allowed)
        #expect(DockAttention.isAllowed(options, bundleID: "dev.toybox.desktop", environment: environment) == allowed)
        #expect(MorningDigest.isAllowed(options, bundleID: "dev.toybox.desktop", environment: environment) == allowed)
        #expect(ChannelSpotlight.indexes(options, bundleID: "dev.toybox.desktop", environment: environment) == allowed)
    }

    @MainActor @Test(arguments: [
        (false, false, false), (true, false, true),
        (false, true, false), (true, true, false),
    ])
    func updaterStartsOnlyWithAReleaseFeedOutsideSnapshots(hasFeedURL: Bool, isSnapshot: Bool, starts: Bool) {
        #expect(AppUpdates.shouldStart(hasFeedURL: hasFeedURL, isSnapshot: isSnapshot) == starts)
    }

    @MainActor @Test(arguments: [false, true])
    func developmentAndSnapshotBundlesNeverCreateAnUpdater(_ isSnapshot: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let contents = directory.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var info = ["CFBundleIdentifier": "dev.toybox.tests.no-updates", "CFBundlePackageType": "BNDL"]
        if isSnapshot { info["SUFeedURL"] = "https://example.test/appcast.xml" }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: directory))
        #expect((bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil) == isSnapshot)
        let updates = AppUpdates(isSnapshot: isSnapshot, bundle: bundle)
        #expect(!updates.isRunning)
        #expect(!updates.canCheckForUpdates)
    }

    @Test func serverIsSessionOnlyAndWinsOverTheEnvironment() throws {
        let options = try LaunchOptions.parse(["--server", "http://127.0.0.1:3210"])
        #expect(options.sessionServer(environment: ["TOY_BOX_SERVER_URL": "http://127.0.0.1:3299"]) == "http://127.0.0.1:3210")
        #expect(!options.allowsUserIntegrations(environment: [:]))
        #expect(throws: LaunchArgumentError("Repeated argument: --server")) {
            try LaunchOptions.parse(["--server", "http://127.0.0.1:3210", "--server", "http://127.0.0.1:3211"])
        }
    }

    @Test func snapshotParsesEveryRequestedSurface() throws {
        let options = try LaunchOptions.parse([
            "--server", "https://example.test/toy-box",
            "--channel", "studio-demo", "--appearance", "dark",
            "--size", "760x560", "--snapshot", "/tmp/shell-test.png", "--state", "inspector"
        ])
        #expect(options.server == "https://example.test/toy-box")
        #expect(options.channelID == "studio-demo")
        #expect(options.appearance == .dark)
        #expect(options.width == 760)
        #expect(options.height == 560)
        #expect(options.snapshotURL?.path == "/tmp/shell-test.png")
        #expect(options.snapshotState == "inspector")
        #expect(options.isSnapshot)
    }

    @MainActor @Test(arguments: ["handoff-match", "handoff-unavailable"])
    func snapshotRetainsAnEarlyReadySignalOnlyForItsExpectedSurface(_ state: String) throws {
        let options = try LaunchOptions.parse([
            "--server", "https://example.test/toy-box", "--channel", "studio-demo",
            "--snapshot", "/tmp/shell-test.png", "--state", state
        ])
        let snapshot = WindowSnapshot(options: options)
        #expect(snapshot.requestedState == nil)
        snapshot.markStateReady("another-state")
        #expect(!snapshot.isStateReady)
        snapshot.markStateReady(state)
        #expect(snapshot.isStateReady)
        #expect(snapshot.isPreparing)
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
        ["--benchmark", "messages"],
        ["--channel", "history-demo", "--benchmark", "wheel"],
        ["--channel", "history-demo", "--benchmark", "paging", "--snapshot", "/tmp/test.png"],
    ])
    func malformedArgumentsFailExplicitly(_ arguments: [String]) {
        #expect(throws: LaunchArgumentError.self) { try LaunchOptions.parse(arguments) }
    }

    @Test func benchmarkNamesItsScenarioAndChannel() throws {
        for scenario in PerformanceBenchmark.Scenario.allCases {
            let options = try LaunchOptions.parse(["--channel", "history-demo", "--benchmark", scenario.rawValue])
            #expect(options.benchmark == scenario)
            #expect(options.channelID == "history-demo")
            #expect(!options.isSnapshot)
        }
        #expect(try LaunchOptions.parse(["--channel", "studio-demo", "--benchmark", "switch"]).benchmark == .switching)
        #expect(try LaunchOptions.parse(["--channel", "studio-demo"]).benchmark == nil)
    }

    /// The window goes to the corner farthest from the parked pointer, or stays put without room.
    @Test func benchmarkWindowOpensAwayFromThePointer() {
        let size = CGSize(width: 1280, height: 840)
        let screen = CGRect(x: 0, y: 0, width: 2880, height: 1575)
        let origin = BenchmarkWindowPlacement.origin(awayFrom: CGPoint(x: 1308, y: 1173), size: size, in: screen)
        #expect(origin == CGPoint(x: 1600, y: 0))
        // The resize edge counts as covering a pointer just outside the frame.
        #expect(BenchmarkWindowPlacement.covers(CGRect(origin: .zero, size: size), CGPoint(x: 1290, y: 400)))
        let small = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(BenchmarkWindowPlacement.origin(awayFrom: CGPoint(x: 720, y: 440), size: size, in: small) == nil)
    }

    /// The transcript centers under the pointer, slides from a screen edge while still under it,
    /// and gives up when the pointer is too near an edge or under the menu bar.
    @Test func benchmarkTranscriptCentersUnderThePointer() {
        let size = CGSize(width: 1280, height: 840)
        let screen = CGRect(x: 0, y: 0, width: 2880, height: 1575)
        let transcript = CGRect(x: 260, y: 120, width: 1000, height: 600)
        func origin(_ x: CGFloat, _ y: CGFloat) -> CGPoint? {
            BenchmarkWindowPlacement.origin(centering: transcript, under: CGPoint(x: x, y: y), size: size, in: screen)
        }
        #expect(origin(1440, 800) == CGPoint(x: 680, y: 380))
        #expect(origin(300, 800) == CGPoint(x: 0, y: 380))
        #expect(origin(100, 800) == nil)
        #expect(origin(1440, 1600) == nil)
    }

    @Test func appKitLaunchPreferencesDoNotBecomeAppArguments() throws {
        let options = try LaunchOptions.parse(["-NSDocumentRevisionsDebugMode", "YES",
                                               "--channel", "studio-demo", "-ApplePersistenceIgnoreState", "YES"])
        #expect(options.channelID == "studio-demo")
    }

    @Test func eachNewWindowHasAnIndependentIdentity() throws {
        let channel = try #require(ChannelTarget(serverURL: "http://127.0.0.1:3210", channelID: "studio-demo"))
        let first = ChannelWindowValue(channel)
        let second = ChannelWindowValue(channel)
        #expect(first.channelID == second.channelID)
        #expect(first != second)
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
        _ = policy.events(channels: [channel], activeChannelID: nil, enabled: true, completions: true)
        channel.seenThrough = 10
        channel.completedSequence = 10
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true, completions: true).isEmpty)
        channel.completedSequence = 11
        channel.latestSequence = 11
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true, completions: true)
            == [.init(channel: channel, sequence: 11, kind: .completion)])
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true, completions: true).isEmpty)
        channel.completedSequence = 12
        channel.latestSequence = 12
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true, completions: false).isEmpty)
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true, completions: true).isEmpty)
        policy = ChannelNotifications.Policy()
        #expect(policy.events(channels: [channel], activeChannelID: nil, enabled: true, completions: true).isEmpty)
    }

    @MainActor @Test func notificationDefaultsDeliverRequestsButNotCompletions() {
        var policy = ChannelNotifications.Policy()
        var request = testChannel(id: "request")
        var completion = testChannel(id: "completion")
        _ = policy.events(channels: [request, completion], activeChannelID: nil, enabled: true)
        request.requestSequence = 11
        request.latestSequence = 11
        completion.completedSequence = 11
        completion.latestSequence = 11
        #expect(policy.events(channels: [request, completion], activeChannelID: nil, enabled: true)
            == [.init(channel: request, sequence: 11, kind: .request)])
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
        #expect(AppModel.attentionCount(channels: channels, openChannelIDs: []) == 3)
        #expect(AppModel.attentionCount(channels: channels, openChannelIDs: ["request", "finished", "unread"]) == 1)
        #expect(AppModel.attentionCount(channels: [finished, unread], openChannelIDs: ["finished", "unread"]) == 0)
        #expect(AppModel.attentionCount(channels: [], openChannelIDs: []) == 0)
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
    /// These SwiftUI-only rows render synchronously, without a window or a display-settling wait.
    private func secondLine(width: CGFloat, directory: String? = nil, purpose: String? = nil,
                            working count: Int, attention: Channel.Attention? = .unread)
        throws -> (faces: Int, detailEnd: CGFloat) {
        let agents = ["#ff0000", "#00ff00", "#0000ff", "#808080", "#808080"].enumerated().map { index, color in
            ChannelAgent(id: "agent-\(index)", name: "Agent \(index)",
                         avatar: .init(mark: "M4 12H20", color: color))
        }
        let channel = Channel(id: "yield", name: "Yield", purpose: purpose, directory: directory,
                              model: .init(provider: "test", name: "test"), updatedAt: "2026-10-22T08:00:00Z")
        let renderer = ImageRenderer(content:
            ChannelSidebarRow(channel: channel, agents: agents, working: Array(agents.prefix(count)), attention: attention,
                              folder: directory == nil ? nil : .remote(host: "elsewhere"),
                              openFolder: {}, onTap: {})
                .frame(width: width, height: 60)
                .background(Color.white)
                .environment(\.colorScheme, .light))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(drawn)
        var counts = [0, 0, 0]
        var stackStart = image.width
        var top = Int.max, bottom = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                for channel in 0..<3 where Int(pixels[offset + channel]) - Int(pixels[offset + (channel + 1) % 3]) > 89
                    && Int(pixels[offset + channel]) - Int(pixels[offset + (channel + 2) % 3]) > 89 {
                    counts[channel] += 1
                    stackStart = min(stackStart, x)
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
            }
        }
        var detailEnd = 0
        for y in 0..<image.height where y >= top && y <= bottom {
            for x in 0..<stackStart {
                let offset = (y * image.width + x) * 4
                let red = pixels[offset], green = pixels[offset + 1], blue = pixels[offset + 2]
                if max(red, green, blue) < 204 && max(red, green, blue) - min(red, green, blue) < 20 {
                    detailEnd = max(detailEnd, x + 1)
                }
            }
        }
        // A partly covered face is about 120 square points. The 7-point unread dot is under 40.
        let scale = CGFloat(image.width) / width
        return (counts.filter { CGFloat($0) > 60 * scale * scale }.count, CGFloat(detailEnd) / scale)
    }

    @Test(arguments: [false, true])
    func rowsGiveUpFacesBeforeTheirFolderOrReadablePurposeStem(_ showsFolder: Bool) throws {
        let directory = showsFolder ? "/tmp/toy-box-mac" : nil
        let purpose = showsFolder ? nil : "Build a welcoming native Mac client"
        let whole = try secondLine(width: 320, directory: directory, purpose: purpose, working: 5)
        #expect(whole.faces == 3)
        let narrow = try secondLine(width: showsFolder ? 211 : 188,
                                    directory: directory, purpose: purpose, working: 5)
        #expect(narrow.faces == 1)
        if showsFolder {
            #expect(narrow.detailEnd == whole.detailEnd, "The folder truncated before giving up faces")
        } else {
            #expect(narrow.detailEnd - 48 >= 55, "The purpose lost its readable stem")
        }
        let squeezed = try secondLine(width: showsFolder ? 198 : 174,
                                      directory: directory, purpose: purpose, working: 5)
        #expect(squeezed.faces == 1 && squeezed.detailEnd < narrow.detailEnd)
        #expect(try secondLine(width: 320, directory: directory, purpose: purpose, working: 0).faces == 0,
                "Idle team members appeared in the working stack")
    }
}

@MainActor
@Suite("Sidebar connection footer")
struct SidebarConnectionFooterTests {
    @Test func theFooterFollowsTheCatalogPhase() {
        func shown(_ phase: ChannelCatalogPhase?, loaded: Bool) -> String {
            SidebarFooter(phase: phase, isLoaded: loaded).accessibilityValue
        }
        let offline = URLError(.cannotConnectToHost)
        #expect(shown(.connecting, loaded: false) == "connecting")
        #expect(shown(.connected, loaded: true) == "connected")
        #expect(shown(.failed(offline), loaded: true) == "reconnecting")
        #expect(shown(.failed(ChannelAPIError.http(status: 502, message: "Bad Gateway")), loaded: true) == "reconnecting")
        #expect(shown(.failed(offline), loaded: false) == "can't connect")
        #expect(shown(nil, loaded: true) == "can't connect", "The server address can't be used")
        for status in [401, 403] {
            #expect(shown(.failed(ChannelAPIError.http(status: status, message: "Refused")), loaded: true)
                == "can't connect", "A refused sign-in never looks temporary")
        }
    }

    @Test func aFailureShowsOnlyAsTheDotWithItsMessageInTheHelp() {
        let offline = URLError(.cannotConnectToHost)
        let footers = [SidebarFooter(phase: .connecting, isLoaded: false), SidebarFooter(phase: .connected, isLoaded: true),
                       SidebarFooter(phase: .failed(offline), isLoaded: true), SidebarFooter(phase: .failed(offline), isLoaded: false)]
        #expect(footers.map(\.dot) == [.secondary, .green, .orange, .red])

        let url = "http://localhost:3100"
        let badGateway = ChannelCatalogPhase.failed(ChannelAPIError.http(status: 502, message: nil))
        let failing = SidebarFooter.Summary(servers: [("Mac mini", SidebarFooter(phase: badGateway, isLoaded: true),
                                                       badGateway.message)])
        #expect(failing.title == "1 server")
        #expect(failing.help == "Reconnecting to Mac mini\nbad gateway (HTTP 502)\nChange servers in Settings.")
        #expect(failing.accessibilityValue == "1 server, reconnecting")
        #expect(failing.accessibilityHint == "Reconnecting to Mac mini\nbad gateway (HTTP 502)",
                "VoiceOver reads the failure as the hint")

        let connected = SidebarFooter.Summary(servers: [("Mac mini", footers[1], nil)])
        #expect(connected.help == "Connected to Mac mini\nChange servers in Settings.")
        #expect(connected.accessibilityValue == "1 server, connected")
        let servers = SidebarFooter.Summary(servers: [("a", footers[1], nil), ("b", footers[3], "offline")])
        #expect(servers.help == "Can't connect to b\noffline\nChange servers in Settings.")
        #expect(SidebarFooter(phase: .connected, isLoaded: true).help(url, failure: nil)
                    == "Connected to http://localhost:3100\nChange the server in Settings.", "A header names its address")
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
        #expect(SidebarFooter.server(url) == shown)
    }

    @Test func severalServersSumUpAsTheLeastHealthy() {
        let offline = URLError(.cannotConnectToHost)
        let connected = SidebarFooter(phase: .connected, isLoaded: true)
        let loading = SidebarFooter(phase: .connecting, isLoaded: false)
        let reconnecting = SidebarFooter(phase: .failed(offline), isLoaded: true)
        let failing = SidebarFooter(phase: .failed(offline), isLoaded: false)
        func summary(_ footers: SidebarFooter...) -> SidebarFooter.Summary {
            .init(servers: footers.enumerated().map { ("s\($0.offset)", $0.element, nil) })
        }

        let healthy = summary(connected, connected)
        #expect(healthy.title == "2 servers")
        #expect(healthy.server == nil && healthy.footer == connected)
        #expect(healthy.status == "Connected to 2 servers")
        #expect(summary(connected).title == "1 server")
        #expect(summary(connected).status == "Connected to s0", "One server is named")
        #expect(summary(loading).status == "Connecting to s0")

        #expect(summary(connected, loading).status == "Connecting to s1")
        #expect(summary(loading, reconnecting, connected).status == "Reconnecting to s1")
        #expect(summary(reconnecting, failing, loading).status == "Can't connect to s1")
        #expect(summary(connected, reconnecting, reconnecting).server == "s1", "The first of the least healthy wins")
    }

    /// A load that lands keeps the main actor busy just as the spinner's delay ends, so the delay's
    /// resume waits in line while the load's end starts a new attempt that settles first.
    @Test func theSpinnerSettlesWhenALoadEndsAsItsDelayDoes() async throws {
        let probe = SpinnerProbe()
        let view = NSHostingView(rootView: SpinnerProbeView(probe: probe))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await probe.until { probe.appeared }

        probe.holdTheMainActor()
        probe.busy = false
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await probe.until { probe.writes.contains(false) }
        await Task.yield()
        #expect(probe.spinning == false, "Writes: \(probe.writes)")
    }
}

@MainActor @Observable private final class SpinnerProbe {
    var busy = true
    var spinning = false
    var writes: [Bool] = []
    var appeared = false

    /// Keeps the main actor busy until well after the spinner's delay ends, so its resume waits in
    /// line.
    nonisolated func holdTheMainActor() {
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Waits for the probe to change until the condition holds, or fails after its own deadline.
    func until(_ condition: () -> Bool) async throws {
        let (changes, change) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let deadline = Task {
            try? await Task.sleep(for: .seconds(10))
            change.finish()
        }
        defer {
            deadline.cancel()
            change.finish()
        }
        var iterator = changes.makeAsyncIterator()
        while !withObservationTracking(condition, onChange: { change.yield() }) {
            guard await iterator.next() != nil else { throw CancellationError() }
        }
    }
}

private struct SpinnerProbeView: View {
    let probe: SpinnerProbe

    var body: some View {
        Color.clear
            .modifier(SpinnerDelay(busy: probe.busy, delay: .milliseconds(20), spinning: Binding(
                get: { probe.spinning }, set: { probe.spinning = $0; probe.writes.append($0) })))
            .task { probe.appeared = true }
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
        view.frame = CGRect(x: 0, y: 0, width: width, height: 40)
        try await waitForShellCondition {
            view.layoutSubtreeIfNeeded()
            return frames.avatar != nil && frames.composer != nil
        }

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

    /// The reconnecting notice floats over the transcript, so its offset below Find's bar is the
    /// only thing keeping the two apart while Find is open offline.
    @MainActor @Test func theReconnectingNoticeClearsFindsBar() {
        let find = TranscriptFind()
        find.present()
        let bar = NSHostingView(rootView: TranscriptFindBar(find: find, channelName: "Studio demo", focusRequest: UUID(),
                                                            navigate: { _ in }, close: {}, announce: { _ in }))
        #expect(bar.fittingSize.height == ReconnectingNotice.findBarHeight)
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

    @Test(arguments: [CGFloat(281), 291, 371, 399])
    func aDraggedInspectorKeepsItsWidthThroughSidebarAndWindowChanges(_ width: CGFloat) {
        let clock = Clock()
        let placement = placement(clock)
        placement.update(windowWidth: 1442)
        clock.advance(1.2)
        placement.update(sidebar: 234.5, inspector: width)
        for sidebar in [CGFloat(0), 234.5] {
            placement.update(sidebar: sidebar, inspector: width)
            #expect(placement.inspectorWidth == width)
            #expect(placement.isWindowNarrow == false)
        }
        placement.update(windowWidth: 980)
        placement.update(sidebar: nil, inspector: nil)
        #expect(placement.isWindowNarrow == true)
        #expect(placement.inspectorWidth == width)
        placement.update(windowWidth: 1442)
        #expect(placement.isWindowNarrow == false)
        #expect(placement.inspectorWidth == width)
    }

    @Test func rememberingTheInspectorWidthDoesNotObserveEveryDragFrame() {
        let clock = Clock()
        let placement = placement(clock)
        let changes = Mutex(0)
        withObservationTracking {
            _ = placement.inspectorWidth
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        for width in [CGFloat(280), 300, 370, 400] {
            placement.update(sidebar: nil, inspector: width)
            #expect(placement.inspectorWidth == width)
        }
        #expect(changes.withLock { $0 } == 0)
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

@MainActor
@Suite("Notification content, replies and withdrawal")
struct NotificationTests {
    private let agents = [ChannelAgent(id: "lead", name: "Lead"), ChannelAgent(id: "ada", name: "Ada Lovelace")]

    private func message(_ text: String, attachments: [ChannelAttachment]? = nil, sequence: Int = 12) -> ChannelMessage {
        ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T08:00:00Z",
                       sender: .init(type: "agent", agentId: "ada"), content: .text(text), request: true,
                       attachments: attachments)
    }

    private func channel(_ id: String, request: Int? = nil, seen: Int = 10) -> Channel {
        Channel(id: id, name: id, model: .init(provider: "test", name: "test"), latestSequence: 20,
                seenThrough: seen, requestSequence: request, updatedAt: "2026-10-22T08:00:00Z")
    }

    private func requestBody(_ message: ChannelMessage) -> String {
        ChannelNotification.Content(request: ChannelRequestMessage(message: message, agents: agents)).body
    }

    @MainActor @Test func requestAlertsLeadWithTheChannelWithoutLosingTheirReplyHandle() {
        let content = ChannelNotifications.content(
            for: .init(channel: channel("Workshop"), sequence: 12, kind: .request),
            serverURL: "https://example.test",
            request: ChannelRequestMessage(message: message("Which entrance should we ship?"), agents: agents)
        )
        #expect(content.title == "Workshop")
        #expect(content.subtitle.isEmpty)
        #expect(content.body == "Which entrance should we ship?")
        #expect(content.userInfo["handle"] as? String == "ada-lovelace")
        #expect(content.userInfo["channelID"] as? String == "Workshop")
        #expect(content.userInfo["sequence"] as? Int == 12)
        #expect(content.categoryIdentifier == "request")
    }

    @Test func requestBodyReadsLikeTheTranscript() {
        let text = """
            @lead @ada-lovelace, which [entrance](https://example.test/a) should we ship?

            - The **arched** one
            - The `flat` one

            ```
            let door = arch
            ```
            """
        #expect(requestBody(message(text)) == """
            which entrance should we ship?
            \u{2022} The arched one
            \u{2022} The flat one
            let door = arch
            """)
    }

    @Test func attachmentOnlyRequestsSayWhatWasSent() {
        let image = ChannelAttachment(name: "door.png", mimeType: "image/png")
        let file = ChannelAttachment(name: "notes.pdf", mimeType: "application/pdf")
        #expect(requestBody(message("@lead", attachments: [image])) == "Sent an image")
        #expect(requestBody(message("", attachments: [image, image, image])) == "Sent 3 images")
        #expect(requestBody(message("", attachments: [file])) == "Sent a file")
        #expect(requestBody(message("", attachments: [image, file])) == "Sent 2 files")
        #expect(requestBody(message("  ")) == ChannelNotification.Content.waitingBody)
    }

    @Test func longRequestsCutAtAWordBoundary() {
        let text = String(repeating: "entrance ", count: 60)
        let body = ChannelNotification.Content.truncated(text)
        #expect(body.count <= ChannelNotification.Content.bodyLimit)
        #expect(body.hasSuffix("entrance\u{2026}"))
        #expect(ChannelNotification.Content.truncated("Short and sweet.") == "Short and sweet.")
        #expect(ChannelNotification.Content.truncated(String(repeating: "a", count: 500)).count
            == ChannelNotification.Content.bodyLimit)
    }

    @Test func repliesAreAddressedLikeTheInAppReply() {
        #expect(ChannelNotification.Reply("  Ship it  ", to: "ada-lovelace")?.content == "@ada-lovelace Ship it")
        #expect(ChannelNotification.Reply("@lead Ship it", to: "ada-lovelace")?.content == "@lead Ship it")
        #expect(ChannelNotification.Reply("Ship it", to: nil)?.content == "Ship it")
        #expect(ChannelNotification.Reply(" \n ", to: "ada-lovelace") == nil)
    }

    @Test func notificationsWithdrawOnceTheyStopBeingTrue() {
        func delivered(_ channel: String, _ kind: String, _ sequence: Int, server: String = "s") -> ChannelNotification.Delivered {
            .init(identifier: "\(server):\(channel):\(kind):\(sequence)", scope: server, channelID: channel,
                  kind: ChannelPushPayload.Kind(rawValue: kind), sequence: sequence)
        }
        let items = [delivered("answered", "request", 11), delivered("waiting", "request", 12),
                     delivered("seen", "completion", 9), delivered("unseen", "completion", 15),
                     delivered("active", "completion", 15), delivered("active", "replyFailed", 0),
                     delivered("waiting", "replyFailed", 0), delivered("deleted", "request", 4),
                     delivered("answered", "request", 11, server: "other")]
        let channels = [channel("answered"), channel("waiting", request: 12), channel("seen"),
                        channel("unseen"), channel("active")]
        #expect(Set(ChannelNotification.Delivered.stale(items, channels: channels, scope: "s", activeChannelID: "active"))
            == ["s:answered:request:11", "s:seen:completion:9", "s:active:completion:15",
                "s:active:replyFailed:0", "s:deleted:request:4"])
    }

    @Test func foregroundPresentationKeepsCompletionsQuiet() {
        #expect(NotificationPresentation.options(kind: "request", isActiveChannel: false) == [.banner, .list, .sound])
        #expect(NotificationPresentation.options(kind: "completion", isActiveChannel: false) == [.list])
        #expect(NotificationPresentation.options(kind: "request", isActiveChannel: true) == [])
    }

    private func requestWithReplies(_ replies: [String]?, sequence: Int = 12) -> ChannelRequestMessage {
        let text = ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T08:00:00Z",
                                  sender: .init(type: "agent", agentId: "ada"), content: .text("Which door?"),
                                  request: true, replies: replies)
        return ChannelRequestMessage(message: text, agents: agents)
    }

    private func requestContent(_ replies: [String]?) -> UNNotificationContent {
        ChannelNotifications.content(
            for: .init(channel: channel("Workshop"), sequence: 12, kind: .request),
            serverURL: "https://example.test", request: requestWithReplies(replies))
    }

    @Test(arguments: [2, 4])
    func suggestedRepliesGetTheirOwnCategoryWithTheReplyFieldFirst(count: Int) {
        let labels = (1...count).map { "Choice \($0)" }
        let content = requestContent(labels)
        #expect(content.categoryIdentifier == ReplyCategories.identifier(labels: labels))
        #expect(content.userInfo["replies"] as? [String] == labels)

        let category = ReplyCategories.category(labels: labels)
        #expect(category.identifier == content.categoryIdentifier)
        #expect(category.actions.count == count + 1)
        #expect(category.actions.first is UNTextInputNotificationAction)
        #expect(category.actions.dropFirst().map(\.title) == labels)
        #expect(category.actions.dropFirst().map(\.identifier) == (0..<count).map { "reply-choice.\($0)" })
    }

    @Test(arguments: [0, 1, 5])
    func requestsWithoutTwoToFourRepliesKeepTheReplyFieldCategory(count: Int) {
        let content = requestContent((0..<count).map { "Choice \($0)" })
        #expect(content.categoryIdentifier == "request")
        #expect(content.userInfo["replies"] == nil)
    }

    @Test func choicesMapToTheirLabelsOnlyWhileInRange() {
        let replies = ["Yes", "No"]
        #expect(SuggestedReplies(replies).label(forAction: "reply-choice.0") == "Yes")
        #expect(SuggestedReplies(replies).label(forAction: "reply-choice.1") == "No")
        #expect(SuggestedReplies(replies).label(forAction: "reply-choice.2") == nil)
        #expect(SuggestedReplies(replies).label(forAction: "reply-choice.x") == nil)
        #expect(SuggestedReplies(nil).label(forAction: "reply-choice.0") == nil)
        #expect(SuggestedReplies(replies).label(forAction: UNNotificationDefaultActionIdentifier) == nil)
    }

    @Test func aReplyOrChoiceSavesForItsOwnServerAndAnswersItsRequest() throws {
        let server = try #require(URL(string: "https://other.example"))
        let info: [AnyHashable: Any] = ["channelID": "workshop", "serverURL": server.absoluteString, "kind": "request",
                                        "sequence": 12, "handle": "ada-lovelace", "replies": ["Yes", "No"]]
        let typed = NotificationReply(action: ChannelNotifications.replyAction, text: " Ship it ", info: info)
        #expect(typed?.content == "@ada-lovelace Ship it")
        #expect(typed?.channelID == "workshop" && typed?.server == server && typed?.request == 12)
        // A choice sends its label as written, with no mention.
        #expect(NotificationReply(action: "reply-choice.1", text: nil, info: info)?.content == "No")
        #expect(NotificationReply(action: "reply-choice.1", text: nil, info: info)?.request == 12)

        #expect(NotificationReply(action: ChannelNotifications.replyAction, text: " \n ", info: info) == nil)
        #expect(NotificationReply(action: "reply-choice.2", text: nil, info: info) == nil)
        #expect(NotificationReply(action: UNNotificationDefaultActionIdentifier, text: nil, info: info) == nil)
        var serverless = info
        serverless["serverURL"] = nil
        #expect(NotificationReply(action: ChannelNotifications.replyAction, text: "Hi", info: serverless) == nil)

        // A reply to a completion answers nothing in particular.
        var completion = info
        completion["kind"] = "completion"
        completion["handle"] = nil
        let reply = NotificationReply(action: ChannelNotifications.replyAction, text: "Thanks", info: completion)
        #expect(reply?.content == "Thanks" && reply?.request == nil)
    }
}

@MainActor
@Suite("Menu bar extra", .timeLimit(.minutes(1)))
struct MenuBarExtraTests {
    private let ada = ChannelAgent(id: "ada", name: "Ada")
    private let nova = ChannelAgent(id: "nova", name: "Nova")
    private let lead = ChannelAgent(id: "lead", name: "Lead")

    private static let server = "http://localhost:3210"

    private func channel(_ id: String, updated: String = "2026-10-22T08:00:00Z", request: Int? = nil) -> Channel {
        Channel(id: id, name: id.capitalized, model: .init(provider: "test", name: "test"), latestSequence: 20,
                seenThrough: 10, requestSequence: request, updatedAt: updated)
    }

    private func target(_ id: String, on server: String = server) -> ChannelTarget {
        ChannelTarget(serverURL: server, channelID: id)!
    }

    private func input(_ channel: Channel, working: [ChannelAgent], on server: String = server) -> MenuBarStatus.Input {
        .init(target: target(channel.id, on: server), channel: channel, working: working)
    }

    private func request(_ text: String, sequence: Int = 12, at timestamp: String = "2026-10-22T08:00:00Z",
                         from sender: String = "ada", replies: [String]? = nil) -> ChannelRequestMessage {
        .init(message: ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: timestamp,
                                      sender: .init(type: "agent", agentId: sender), content: .text(text),
                                      request: true, replies: replies),
              agents: [lead, ada, nova])
    }

    private func waiting(
        _ channel: Channel, _ request: ChannelRequestMessage? = nil, on server: String = server
    ) -> ChannelWaitingRequest {
        .init(serverURL: server, channel: channel, sequence: channel.requestSequence!, request: request)!
    }

    private func waitingItem(_ id: String, _ request: ChannelRequestMessage? = nil) -> MenuBarStatus.Item {
        let channel = channel(id, request: request?.message.sequence ?? 12)
        return MenuBarStatus(requests: [waiting(channel, request)], [], unreachableHost: nil).waiting[0]
    }

    @Test func theIconFollowsTheMostUrgentState() {
        let idle = MenuBarStatus([], unreachableHost: nil)
        #expect(idle.state == .idle && idle.icon == .face && !idle.isActive)
        #expect(idle.accessibilityValue == "No agents working" && idle.emptyText == "No agents are working")

        let offline = MenuBarStatus([], unreachableHost: "studio.local:3100")
        #expect(offline.state == .disconnected && offline.icon == .face && !offline.isActive)
        #expect(offline.accessibilityValue == "Not connected" && offline.emptyText == "Can't connect to studio.local:3100")

        let working = MenuBarStatus([input(channel("a"), working: [ada])], unreachableHost: nil)
        #expect(working.state == .working && working.icon == .working && working.isActive)
        #expect(working.accessibilityValue == "1 agent working" && working.emptyText == nil)

        let waiting = MenuBarStatus(requests: [self.waiting(channel("a", request: 12))], [
            input(channel("a", request: 12), working: [lead, ada]),
            input(channel("b"), working: [nova]),
        ], unreachableHost: "studio.local:3100")
        #expect(waiting.state == .waiting && waiting.icon == .waiting && waiting.isActive)
        #expect(waiting.accessibilityValue == "1 channel waiting for you, 3 agents working")
    }

    @Test func everyIconIsATemplateOnOneCanvas() {
        for icon in MenuBarIcon.allCases {
            #expect(icon.image.size == CGSize(width: 17, height: 16) && icon.image.isTemplate)
            #expect(icon.image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        }
    }

    @Test func waitingChannelsKeepTheSharedOrder() throws {
        let long = "Can you confirm the history review covers paging, search and the outbox before we ship it?"
        let status = MenuBarStatus(requests: [
            waiting(channel("newer", request: 14), request(long, sequence: 14, at: "2026-10-22T09:00:00Z")),
            waiting(channel("older", request: 12), request("Pick a palette\nfor the icon", at: "2026-10-22T08:00:00Z")),
            waiting(channel("unknown", updated: "2026-10-22T07:00:00Z", request: 3)),
        ], [input(channel("newer", request: 14), working: [ada])], unreachableHost: nil)
        #expect(status.waiting.map(\.target.channelID) == ["newer", "older", "unknown"])
        #expect(status.waiting.map(\.request?.sequence) == [14, 12, 3])
        #expect(status.waiting.map(\.agent?.id) == ["ada", "ada", nil])
        #expect(status.waiting[1].subtitle == "Ada needs your reply")
        #expect(status.waiting[2].subtitle == "Needs your reply")
        // A waiting channel stays out of Working even while its agents work.
        #expect(status.working.isEmpty)
    }

    @Test func workingChannelsNameTheirAgentsLeadFirst() {
        #expect(MenuBarStatus.workingSubtitle(["Lead"]) == "Lead is working")
        #expect(MenuBarStatus.workingSubtitle(["Lead", "Ada"]) == "Lead and Ada are working")
        #expect(MenuBarStatus.workingSubtitle(["Lead", "Ada", "Nova"]) == "Lead, Ada and Nova are working")
        #expect(MenuBarStatus.workingSubtitle(["Lead", "Ada", "Nova", "Max"]) == "Lead, Ada and 2 others are working")
        let status = MenuBarStatus([
            input(channel("quiet"), working: []),
            input(channel("early", updated: "2026-10-22T07:00:00Z"), working: [nova]),
            input(channel("late", updated: "2026-10-22T09:00:00Z"), working: [lead, ada]),
        ], unreachableHost: nil)
        #expect(status.working.map(\.target.channelID) == ["late", "early"])
        #expect(status.working.map(\.agent?.id) == ["lead", "nova"])
        #expect(status.workingAgents == 3)
    }

    @Test func workingShowsThreeChannelsThenOpensTheWindowForTheRest() {
        let inputs = (0..<8).map { index in
            input(channel("c\(index)", updated: "2026-10-22T0\(index):00:00Z"), working: [ada])
        }
        let section = MenuBarStatus(inputs, unreachableHost: nil).workingSection
        #expect(section.items.map(\.target.channelID) == ["c7", "c6", "c5"] && section.overflow == 5)
        #expect(section.items.allSatisfy { $0.agents == [ada] })
        #expect(MenuBarStatus(Array(inputs.prefix(3)), unreachableHost: nil).workingSection.overflow == 0)
    }

    @Test func theSameChannelOnTwoServersIsTwoItems() {
        let other = "http://localhost:3211"
        let status = MenuBarStatus(requests: [waiting(channel("studio", request: 12))], [
            input(channel("studio", request: 12), working: [ada]),
            input(channel("studio"), working: [nova], on: other),
        ], unreachableHost: nil)
        #expect(status.waiting.map(\.target) == [target("studio")])
        #expect(status.working.map(\.target) == [target("studio", on: other)])
        var inbox = MenuBarInboxRequests(status: .init(requests: [
            waiting(channel("studio", request: 12), request("Here?")),
            waiting(channel("studio", request: 7), request("There?", sequence: 7), on: other),
        ], [], unreachableHost: nil))
        inbox.record(target("studio", on: other), .replied)
        #expect(inbox.requests.map(\.state) == [.waiting, .replied])
    }

    @Test func anOpenInboxKeepsAnsweredRowsAndAppendsNewRequestsWithoutReordering() {
        let first = MenuBarStatus(requests: [
            waiting(channel("one", request: 12), request("First?")),
            waiting(channel("two", request: 13), request("Second?", sequence: 13)),
        ], [], unreachableHost: nil)
        var inbox = MenuBarInboxRequests(status: first)
        let next = MenuBarStatus(waiting: [
            waitingItem("new", request("New?", sequence: 14)),
            first.waiting[1],
        ])
        inbox.update(next)
        #expect(inbox.requests.map(\.id.channelID) == ["one", "two", "new"])
        #expect(inbox.requests[0].state == .answered)
        #expect(!inbox.requests[0].canReply)
        #expect(inbox.requests[1].canReply)
        #expect(MenuBarInboxRequests(status: next).requests.map(\.id.channelID) == ["new", "two"])
    }

    @Test func aChangedRequestKeepsTheOriginalQuoteAndDisablesItsReply() {
        let item = waitingItem("one", request("First?"))
        var inbox = MenuBarInboxRequests(status: .init(waiting: [item]))
        let newer = waitingItem("one", request("Different question?", sequence: 20))
        inbox.update(.init(waiting: [newer]))
        #expect(inbox.requests[0].item == item)
        #expect(inbox.requests[0].state == .newerRequest)
        #expect(!inbox.requests[0].canReply)
    }

    @Test func aRepliedRowStaysUntilTheNextOpening() {
        let item = waitingItem("one", request("First?"))
        var inbox = MenuBarInboxRequests(status: .init(waiting: [item]))
        inbox.record(target("one"), .replied)
        inbox.update(.init(waiting: [item]))
        #expect(inbox.requests[0].state == .replied)
        #expect(!inbox.requests[0].canReply)
        // The outbox answers the request at once, which drops it from waiting without "answered elsewhere".
        inbox.update(.init())
        #expect(inbox.requests.map(\.state) == [.replied])
        #expect(inbox.requests[0].item == item)
        #expect(MenuBarInboxRequests(status: .init()).requests.isEmpty)
    }

    @Test func previewArrivalEnablesReplyWithoutInventingARequester() {
        var inbox = MenuBarInboxRequests(status: .init(waiting: [waitingItem("one")]))
        #expect(!inbox.requests[0].canReply)
        inbox.update(.init(waiting: [waitingItem("one", request("Question?", from: "gone"))]))
        #expect(!inbox.requests[0].canReply)
        inbox.update(.init(waiting: [waitingItem("one", request("Question?"))]))
        #expect(inbox.requests[0].canReply)
    }

    @Test func choicesShowWhileTheRequestWaitsAndNeedNoRequester() {
        let item = waitingItem("one", request("Ship it?", from: "gone", replies: ["Yes", "No"]))
        var inbox = MenuBarInboxRequests(status: .init(waiting: [item]))
        #expect(inbox.requests[0].choices(isConnected: true) != nil)
        #expect(!inbox.requests[0].canReply)
        inbox.record(target("one"), .replied)
        #expect(inbox.requests[0].choices(isConnected: true) == nil)
        #expect(inbox.requests[0].state.notice == "Replied")
    }

    @Test func aRequestWithoutSuggestedRepliesOffersNoChoices() {
        let inbox = MenuBarInboxRequests(status: .init(waiting: [waitingItem("one", request("Ship it?"))]))
        #expect(inbox.requests[0].canReply)
        #expect(inbox.requests[0].choices(isConnected: true) == nil)
    }

    @Test func choicesDisableWhileTheCatalogCannotConnect() throws {
        let item = waitingItem("one", request("Ship it?", replies: ["Yes", "No"]))
        let request = MenuBarInboxRequests(status: .init(waiting: [item])).requests[0]
        #expect(try #require(request.choices(isConnected: true)).canSend)
        let offline = try #require(request.choices(isConnected: false))
        #expect(offline.labels == ["Yes", "No"] && !offline.canSend)
    }

    @Test func aShortRequestTakesItsLinesAndALongOneScrollsWithinTheCap() throws {
        func scrollView(for quote: String) throws -> NSScrollView {
            let host = NSHostingView(rootView: MenuBarInboxRequestText(quote: quote, presentationID: UUID())
                .frame(width: 348)
                .fixedSize(horizontal: false, vertical: true))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 348, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            return try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        }
        let short = try scrollView(for: "Where should the shared library sit?")
        let shortContent = try #require(short.documentView).frame.height
        #expect(short.frame.height == shortContent)
        #expect(shortContent > 0 && shortContent < 40)
        let long = try scrollView(for: String(repeating: "The request keeps going with constraints. ", count: 40))
        #expect(long.frame.height == MenuBarInboxRequestText.maximumHeight)
        #expect(try #require(long.documentView).frame.height > 2 * MenuBarInboxRequestText.maximumHeight)
    }

    @Test func aLongRequestFadesItsBottomUntilTheReaderReachesTheEnd() {
        func opacity(offset: CGFloat, content: CGFloat) -> Double {
            let geometry = ScrollGeometry(contentOffset: CGPoint(x: 0, y: offset),
                                          contentSize: CGSize(width: 348, height: content),
                                          contentInsets: EdgeInsets(),
                                          containerSize: CGSize(width: 348, height: min(content, 160)))
            return MenuBarInboxRequestText.endOpacity(hiddenBelow: MenuBarInboxRequestText.hiddenBelow(geometry))
        }
        #expect(opacity(offset: 0, content: 16) == 1)
        #expect(opacity(offset: 0, content: 544) == 0)
        #expect(opacity(offset: 372, content: 544) == 0.5)
        #expect(opacity(offset: 384, content: 544) == 1)
        #expect(opacity(offset: 400, content: 544) == 1)
    }

    @Test func whenActiveLingersAfterActivityAndHoldsWhileAMenuIsOpen() async throws {
        let center = NotificationCenter()
        let menu = NSMenu()
        let presence = MenuBarPresence(linger: .milliseconds(50), center: center)
        #expect(!presence.isInserted)
        presence.update(isActive: true)
        #expect(presence.isInserted)
        presence.update(isActive: false)
        #expect(presence.isInserted)
        await presence.linger?.value
        #expect(!presence.isInserted)

        presence.update(isActive: true)
        presence.update(isActive: false)
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        await presence.linger?.value
        #expect(presence.isInserted)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(!presence.isInserted)

        presence.update(isActive: true)
        presence.update(isActive: false)
        center.post(NSMenu.DidBeginTrackingMessage(menu: menu), subject: menu)
        await presence.linger?.value
        #expect(presence.isInserted)
        center.post(NSMenu.DidEndTrackingMessage(menu: menu), subject: menu)
        #expect(!presence.isInserted)

        presence.update(isActive: true)
        presence.popoverVisibilityChanged(true)
        presence.update(isActive: false)
        await presence.linger?.value
        center.post(NSMenu.DidBeginTrackingMessage(menu: menu), subject: menu)
        center.post(NSMenu.DidEndTrackingMessage(menu: menu), subject: menu)
        #expect(presence.isInserted)
        presence.popoverVisibilityChanged(false)
        #expect(!presence.isInserted)

        // Activity that resumes inside the linger keeps the item without a gap.
        presence.update(isActive: true)
        presence.update(isActive: false)
        let interrupted = presence.linger
        presence.update(isActive: true)
        await interrupted?.value
        #expect(presence.isInserted)
    }

    @Test func alwaysAndNeverIgnoreActivity() {
        let presence = MenuBarPresence(linger: .milliseconds(50))
        presence.visibility = .always
        #expect(presence.isInserted)
        presence.visibility = .never
        presence.update(isActive: true)
        #expect(!presence.isInserted)
        presence.visibility = .whenActive
        #expect(presence.isInserted)
        // A hidden item doesn't linger, and a menu that opens elsewhere never brings it back.
        presence.visibility = .never
        presence.update(isActive: false)
        presence.menuTracking(true)
        presence.visibility = .whenActive
        #expect(!presence.isInserted)
    }

    @Test func settingsNameWhyIntelligenceIsOff() {
        #expect(SettingsView.unavailableText(.deviceNotEligible) == "This Mac doesn't support Apple Intelligence.")
        #expect(SettingsView.unavailableText(.appleIntelligenceNotEnabled)
            == "Turn on Apple Intelligence in System Settings to use these.")
        #expect(SettingsView.unavailableText(.modelNotReady) == "Apple Intelligence is getting ready. Try again later.")
        #expect(SettingsView.unavailableText(.unsupportedLanguage)
            == "Apple Intelligence doesn't support your Mac's language yet.")
    }
}

@Suite("Launch channel")
final class LaunchChannelTests {
    private let suite = "launch-channel-\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    @Test func eachServerRemembersItsOwnChannel() {
        let memory = LaunchChannel(defaults: defaults)
        #expect(memory.channelID(serverURL: "http://a.test/") == nil)
        memory.remember("studio", serverURL: "http://a.test/")
        memory.remember("launch", serverURL: "http://b.test/")
        memory.remember("docs", serverURL: "http://a.test/")
        #expect(memory.channelID(serverURL: "http://a.test/") == "docs")
        #expect(memory.channelID(serverURL: "http://b.test/") == "launch")
        #expect(memory.channelID(serverURL: "http://c.test/") == nil)
    }

    @Test func theMemoryLivesInDefaultsNotTheValue() {
        LaunchChannel(defaults: defaults).remember("docs", serverURL: "http://a.test/")
        #expect(LaunchChannel(defaults: defaults).channelID(serverURL: "http://a.test/") == "docs")
    }
}

@Suite("Channel title fit")
@MainActor
struct ChannelTitleFitTests {
    typealias Span = ChannelTitleFit.Span
    let long = "Quarterly launch readiness review and retrospective planning"

    @Test func theIdealWidthMatchesTheTitleMenusLayout() {
        // The 24-point avatar, 6 points in and 8 before 438 points of semibold text, which ends 12
        // points before the capsule's end.
        #expect(abs(ChannelTitleFit.idealWidth(of: long) - 488) <= 2)
        #expect(ChannelTitleFit.idealWidth(of: "Studio demo") < 156)
    }

    @Test func theNarrowestWindowKeepsEveryControl() {
        // The title starts 8 points past the 248-point sidebar and ends 24 points, plus the item's
        // inset, before the trailing controls at 667.
        let room = ChannelTitleFit.room(detail: Span(minX: 248, maxX: 760), windowWidth: 760)
        #expect(room == 383)
        #expect(ChannelTitleFit.maxWidth(idealWidth: 465, room: room) == 383)
    }

    @Test func aCollapsedSidebarStartsTheTitleAfterTheSidebarButton() {
        #expect(ChannelTitleFit.room(detail: Span(minX: 0, maxX: 760), windowWidth: 760) == 499)
        // The sidebar's collapse animation passes through widths narrower than the buttons it covers.
        #expect(ChannelTitleFit.room(detail: Span(minX: 120, maxX: 760), windowWidth: 760) == 499)
    }

    @Test func anOpenOverviewStopsTheTitleShortOfIt() {
        let room = ChannelTitleFit.room(detail: Span(minX: 248, maxX: 688), windowWidth: 1000)
        #expect(room == 360)
        #expect(ChannelTitleFit.room(detail: Span(minX: 248, maxX: 968), windowWidth: 1280) == 640)
    }

    @Test func aTitleThatFitsHasNoCap() {
        #expect(ChannelTitleFit.maxWidth(idealWidth: 465, room: 465) == nil)
        #expect(ChannelTitleFit.maxWidth(idealWidth: 102, room: 350) == nil)
        #expect(ChannelTitleFit.maxWidth(idealWidth: 465, room: 420.5) == 420)
        #expect(ChannelTitleFit.maxWidth(idealWidth: 465, room: -20) == ChannelTitleFit.minimumWidth)
    }

    @Test func theCapWaitsForLayoutAndFollowsTheTitle() {
        let fit = ChannelTitleFit()
        fit.update(title: long)
        fit.update(detail: Span(minX: 0, maxX: 100))
        fit.update(windowWidth: 100)
        #expect(fit.maxWidth == nil)
        fit.update(detail: Span(minX: 248, maxX: 760))
        fit.update(windowWidth: 760)
        #expect(fit.maxWidth == 383)
        fit.update(title: "Studio demo")
        #expect(fit.maxWidth == nil)
    }

    @Test func aTitleThatFitsNeverRedrawsDuringAResize() {
        let fit = ChannelTitleFit()
        fit.update(title: "Studio demo")
        fit.update(detail: Span(minX: 248, maxX: 1280))
        fit.update(windowWidth: 1280)
        let changes = Mutex(0)
        withObservationTracking { _ = fit.maxWidth } onChange: { changes.withLock { $0 += 1 } }
        for width in stride(from: CGFloat(1280), through: 760, by: -7) {
            fit.update(detail: Span(minX: 248, maxX: width))
            fit.update(windowWidth: width)
        }
        #expect(changes.withLock { $0 } == 0)
    }
}

@MainActor private func waitForShellCondition(
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "The expected Shell state never arrived.",
                     sourceLocation: sourceLocation)
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Siri reads only the channel or artifact in the frontmost window, which the entities' queries
/// resolve from what each window shows.
@Suite("Siri's on-screen content")
@MainActor
struct SiriOnScreenTests {
    @Test func siriReadsTheChannelInTheFrontWindowAndOnlyNamesOthers() async throws {
        let launch = channel("launch", "Launch")
        let api = try ChannelAPI(serverURL: "https://fixture.example")
        let request = ChannelMessage(id: "m2", sequence: 2, timestamp: "2026-11-05T12:01:00Z", sender: .agent("lead"),
                                     content: .text("Ship it?"), request: true)
        let store = ChannelStore(id: "launch", api: api)
        _ = try store.apply(.init(type: "snapshot", state: ChannelState(
            revision: 1, channel: launch, lead: .lead(id: "lead", profile: Self.lead), members: [],
            messages: [ChannelMessage(id: "m1", sequence: 1, timestamp: "2026-11-05T12:00:00Z", sender: .user,
                                      content: .text("Can you **check** the build?")), request],
            request: request)))
        var shown: ChannelIntents.OnScreen? = .channel(store)
        let context = intents(channels: [launch, channel("other", "Other")]) { shown }
        let text = store.readableText(name: "Launch")
        #expect(text.contains("Ship it?"))
        let launchID = try #require(store.target).identifier
        let otherID = try Self.target("other").identifier

        // Siri resolves the window's channel from its live store.
        let resolved = try await context.entities(for: [launchID])
        #expect(resolved.map(\.content) == [text])
        let exported = try await #require(resolved.first).exported(as: .utf8PlainText)
        #expect(String(decoding: exported, as: UTF8.self) == text)

        // Any other channel keeps only what the sidebar shows, and so does Shortcuts' list.
        let named = try await context.entities(for: [launchID, otherID, "missing"])
        #expect(named.map(\.id) == [launchID, otherID])
        #expect(named.map(\.content) == [text, ""])
        #expect(try await context.entities().map(\.content) == [text, ""])

        // Once the window shows an artifact or nothing Siri may read, the channel keeps only its name.
        shown = .artifact(ChannelArtifactSession(decodeImage: { _, _, _ in throw ChannelAttachmentError.invalidImage }),
                          in: store)
        #expect(try await context.entities(for: [launchID]).map(\.content) == [""])
        shown = nil
        #expect(try await context.entities(for: [launchID]).map(\.content) == [""])
    }

    @Test func siriReadsTheOpenMarkdownArtifactAndOnlyNamesOtherKinds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shell-siri-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("# Plan\n\nShip **it** today.".utf8).write(to: directory.appendingPathComponent("plan.md"))
        try Data("<html><script>track()</script><p>Page</p></html>".utf8)
            .write(to: directory.appendingPathComponent("page.html"))
        let session = ChannelArtifactSession(decodeImage: { _, _, _ in throw ChannelAttachmentError.invalidImage },
                                             download: { artifact, _ in directory.appendingPathComponent(artifact.file.path) })
        defer { session.close() }
        let plan = ChannelArtifact(file: .init(kind: "machine", path: "plan.md"), title: "Plan",
                                   url: "/api/serve/launch/plan.md")
        let page = ChannelArtifact(file: .init(kind: "machine", path: "page.html"), title: "Page",
                                   url: "/api/serve/launch/page.html")
        let store = ChannelStore(id: "launch", api: try ChannelAPI(serverURL: "https://fixture.example"))
        session.configure(api: store.api, channelID: "launch", artifacts: [plan, page])
        let context = intents { .artifact(session, in: store) }
        let planID = ArtifactEntity.id(channelID: "launch", artifactID: plan.id)
        let pageID = ArtifactEntity.id(channelID: "launch", artifactID: page.id)
        #expect(context.artifacts(for: [planID]).isEmpty)

        session.open(plan)
        await session.loadTask?.value
        let shown = context.artifacts(for: [planID, pageID])
        #expect(shown.map(\.id) == [planID])
        #expect(shown.map(\.title) == ["Plan"] && shown.map(\.kind) == ["Markdown"])
        #expect(shown.map(\.content) == [session.readableText] && session.readableText.contains("Ship it today."))
        let exported = try await #require(shown.first).exported(as: .utf8PlainText)
        #expect(String(decoding: exported, as: UTF8.self) == session.readableText)

        #expect(session.select(page.id))
        await session.loadTask?.value
        #expect(session.content?.text != nil)
        let html = context.artifacts(for: [planID, pageID])
        #expect(html.map(\.id) == [pageID] && html.map(\.kind) == ["HTML"] && html.map(\.content) == [""])

        session.close()
        #expect(context.artifacts(for: [pageID]).isEmpty)
    }

    @Test func siriSeesOnlyWhatAChannelWindowStillShows() throws {
        let catalog = ChannelCatalogStore(api: try ChannelAPI(serverURL: "https://fixture.example"))
        let store = catalog.channel(id: "launch")
        let window = NSWindow()
        let session = ChannelArtifactSession(decodeImage: { _, _, _ in throw ChannelAttachmentError.invalidImage },
                                             download: { _, _ in throw URLError(.cannotConnectToHost) })
        defer { session.close() }
        let launch = try Self.target("launch")
        func shown(_ entity: ScreenEntity, in front: NSWindow? = nil, catalogs: [ChannelCatalogStore]? = nil) -> String? {
            let screen = ChannelIntents.Screen(window: window, entity: entity, artifacts: session)
            return switch ChannelIntents.Screen.onScreen(in: front ?? window, screens: [screen],
                                                         catalogs: catalogs ?? [catalog]) {
            case .channel(let shown): "channel \(shown.id)"
            case .artifact(let shown, let owner): "artifact \(owner.id)/\(shown.artifact?.id ?? "")"
            case nil: nil
            }
        }

        #expect(shown(.channel(launch)) == "channel launch")
        // Another window in front, like Settings, shows Siri nothing.
        #expect(shown(.channel(launch), in: NSWindow()) == nil)
        // Neither does a channel with no store, or one on a server you removed.
        #expect(shown(.channel(try Self.target("other"))) == nil)
        let next = ChannelCatalogStore(api: try ChannelAPI(serverURL: "https://next.example"))
        #expect(shown(.channel(launch), catalogs: [next]) == nil)
        // The same channel ID on another server reads that server's store.
        let elsewhere = next.channel(id: "launch")
        let screen = ChannelIntents.Screen(window: window, entity: .channel(try #require(elsewhere.target)),
                                           artifacts: session)
        if case .channel(let resolved) = ChannelIntents.Screen.onScreen(in: window, screens: [screen],
                                                                         catalogs: [catalog, next]) {
            #expect(resolved === elsewhere)
        } else { Issue.record("The window should show the other server's channel") }

        let artifact = ChannelArtifact(file: .init(kind: "machine", path: "plan.md"), title: "Plan")
        let open = ScreenEntity.artifact(launch, artifactID: artifact.id)
        #expect(shown(open) == nil)
        session.configure(api: store.api, channelID: "launch", artifacts: [artifact])
        session.open(artifact)
        #expect(shown(open) == "artifact launch/\(artifact.id)")
        // The viewer closes its artifact at once, before it fades.
        session.close()
        #expect(shown(open) == nil)
    }

    @Test func spotlightNeverGetsTheContent() throws {
        let entity = ChannelEntity(try Self.target("launch"), name: "Launch", purpose: "Ship the app",
                                   content: "Siri-only text")
        let archive = try NSKeyedArchiver.archivedData(withRootObject: entity.attributeSet, requiringSecureCoding: true)
        #expect(archive.range(of: Data("Ship the app".utf8)) != nil)
        #expect(archive.range(of: Data("Siri-only text".utf8)) == nil)
    }

    private static let lead = ChannelLeadProfile(name: "Lead", role: "Coordinator",
                                                 avatar: .init(mark: "M4 12H20", color: "#123456"))

    private func channel(_ id: String, _ name: String) -> Channel {
        Channel(id: id, name: name, purpose: "Ship **the** app", model: .init(provider: "test", name: "test"),
                updatedAt: "2026-11-05T12:00:00Z")
    }

    private static func target(_ id: String) throws -> ChannelTarget {
        try #require(ChannelTarget(serverURL: "https://fixture.example", channelID: id))
    }

    private func intents(channels: [Channel] = [],
                         onScreen: @escaping @MainActor () -> ChannelIntents.OnScreen?) -> ChannelIntents {
        ChannelIntents(host: .init(api: { _ in nil },
                                   channels: { try channels.map { .init(target: try Self.target($0.id), channel: $0) } },
                                   store: { _ in nil }, hold: { _ in }, release: { _ in },
                                   send: { _ in Issue.record("Reading never sends") }, open: { _ in }, onScreen: onScreen))
    }
}
