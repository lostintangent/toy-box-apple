import AppKit
import Carbon
import ChannelKit
import ChannelClient
import ChannelIntelligence
import Observation
import SwiftUI
import ToyBoxUI
import Synchronization
import Testing
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

    @Test func snapshotsAndBothBenchmarksNeverRegisterOrPresent() {
        var snapshot = LaunchOptions()
        snapshot.snapshotURL = URL(fileURLWithPath: "/tmp/quick-send-test.png")
        var benchmark = LaunchOptions()
        benchmark.benchmark = .scroll
        var resize = LaunchOptions()
        resize.resizeBenchmark = .width
        for options in [snapshot, benchmark, resize] {
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
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
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
        #expect(options.serverURL == nil)
        #expect(options.channelID == nil)
        #expect(options.appearance == nil)
        #expect(options.width == 1280)
        #expect(options.height == 840)
        #expect(!options.isSnapshot)
        #expect(options.quickSendValidation == nil)
    }

    @MainActor @Test(arguments: [
        [], ["--server", "http://127.0.0.1:3210"],
        ["--channel", "studio-demo", "--snapshot", "/tmp/integrations.png"],
        ["--channel", "studio-demo", "--benchmark", "launch"],
        ["--channel", "studio-demo", "--benchmark-resize", "width"],
        ["--validate-quick-send", "hold"],
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
        ["--channel", "studio-demo", "--benchmark-resize", "drag"],
        ["--channel", "studio-demo", "--benchmark-resize", "width", "--snapshot", "/tmp/test.png"],
        ["--benchmark", "messages"],
        ["--channel", "history-demo", "--benchmark", "wheel"],
        ["--channel", "history-demo", "--benchmark", "paging", "--snapshot", "/tmp/test.png"],
        ["--channel", "history-demo", "--benchmark", "paging", "--benchmark-resize", "width"],
        ["--validate-quick-send", "yes"],
        ["--validate-quick-send"],
        ["--validate-quick-send", "trace", "--validate-quick-send", "hold"],
        ["--channel", "studio-demo", "--snapshot", "/tmp/test.png", "--validate-quick-send", "hold"],
        ["--channel", "studio-demo", "--benchmark", "scroll", "--validate-quick-send", "trace"],
        ["--channel", "studio-demo", "--benchmark-resize", "width", "--validate-quick-send", "hold"]
    ])
    func malformedArgumentsFailExplicitly(_ arguments: [String]) {
        #expect(throws: LaunchArgumentError.self) { try LaunchOptions.parse(arguments) }
    }

    @Test func quickSendValidationIsExplicitAndCommandLineOverridesItsLaunchEnvironment() throws {
        #expect(try LaunchOptions.parse(["--validate-quick-send", "trace"]).quickSendValidation == .trace)
        #expect(try LaunchOptions.parse([], environment: ["TOY_BOX_QUICK_SEND_VALIDATION": "hold"])
            .quickSendValidation == .hold)
        #expect(try LaunchOptions.parse(["--validate-quick-send", "trace"],
                                       environment: ["TOY_BOX_QUICK_SEND_VALIDATION": "hold"])
            .quickSendValidation == .trace)
        #expect(throws: LaunchArgumentError.self) {
            try LaunchOptions.parse([], environment: ["TOY_BOX_QUICK_SEND_VALIDATION": "yes"])
        }
        #expect(throws: LaunchArgumentError.self) {
            try LaunchOptions.parse(["--channel", "studio-demo", "--benchmark", "scroll"],
                                    environment: ["TOY_BOX_QUICK_SEND_VALIDATION": "hold"])
        }
    }

    @Test func resizeBenchmarkNamesItsModeAndChannel() throws {
        let width = try LaunchOptions.parse(["--channel", "studio-demo", "--benchmark-resize", "width"])
        #expect(width.resizeBenchmark == .width)
        #expect(width.resizeBenchmark?.drags == false)
        #expect(!width.isSnapshot)
        let both = try LaunchOptions.parse(["--channel", "studio-demo", "--benchmark-resize", "both"])
        #expect(both.resizeBenchmark?.axis == .both)
        let drag = try LaunchOptions.parse(["--channel", "studio-demo", "--benchmark-resize", "drag-width"])
        #expect(drag.resizeBenchmark?.axis == .width)
        #expect(drag.resizeBenchmark?.drags == true)
        #expect(try LaunchOptions.parse(["--channel", "studio-demo", "--benchmark-resize", "drag-both"])
            .resizeBenchmark?.axis == .both)
        #expect(try LaunchOptions.parse(["--channel", "studio-demo"]).resizeBenchmark == nil)
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

    /// These SwiftUI-only rows render synchronously, without a window or a display-settling wait.
    private func secondLine(width: CGFloat, directory: String? = nil, purpose: String? = nil,
                            working count: Int, attention: ChannelAttention? = .unread)
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

    @Test func theSpinnerKeepsTheSameStatusLineSize() {
        func size(spinning: Bool) -> CGSize {
            NSHostingView(rootView:
                SidebarStatusLine(connection: .reconnecting, spinning: spinning, serverURL: "http://localhost:3100")
            ).fittingSize
        }
        let resting = size(spinning: false)
        #expect(resting.width > 60 && resting.height > 0)
        #expect(size(spinning: true) == resting)
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

    @Test func requestBodyReadsLikeTheTranscript() {
        let text = """
            @lead @ada-lovelace, which [entrance](https://example.test/a) should we ship?

            - The **arched** one
            - The `flat` one

            ```
            let door = arch
            ```
            """
        #expect(NotificationText.requestBody(message(text), agents: agents) == """
            which entrance should we ship?
            \u{2022} The arched one
            \u{2022} The flat one
            let door = arch
            """)
    }

    @Test func attachmentOnlyRequestsSayWhatWasSent() {
        let image = ChannelAttachment(name: "door.png", mimeType: "image/png")
        let file = ChannelAttachment(name: "notes.pdf", mimeType: "application/pdf")
        #expect(NotificationText.requestBody(message("@lead", attachments: [image]), agents: agents) == "Sent an image")
        #expect(NotificationText.requestBody(message("", attachments: [image, image, image]), agents: agents) == "Sent 3 images")
        #expect(NotificationText.requestBody(message("", attachments: [file]), agents: agents) == "Sent a file")
        #expect(NotificationText.requestBody(message("", attachments: [image, file]), agents: agents) == "Sent 2 files")
        #expect(NotificationText.requestBody(message("  "), agents: agents) == NotificationText.waitingBody)
    }

    @Test func longRequestsCutAtAWordBoundary() {
        let text = String(repeating: "entrance ", count: 60)
        let body = NotificationText.truncated(text)
        #expect(body.count <= NotificationText.bodyLimit)
        #expect(body.hasSuffix("entrance\u{2026}"))
        #expect(NotificationText.truncated("Short and sweet.") == "Short and sweet.")
        #expect(NotificationText.truncated(String(repeating: "a", count: 500)).count == NotificationText.bodyLimit)
    }

    @Test func completionNamesASingleTask() {
        #expect(NotificationText.completionBody(tasks: [.init(id: "1", title: "Ship the door")])
            == "Completed \u{201C}Ship the door\u{201D}")
        #expect(NotificationText.completionBody(tasks: [.init(id: "1", title: "A"), .init(id: "2", title: "B")])
            == "All 2 tasks completed")
    }

    @Test func repliesAreAddressedLikeTheInAppReply() {
        #expect(NotificationText.addressedReply("  Ship it  ", to: "ada-lovelace") == "@ada-lovelace Ship it")
        #expect(NotificationText.addressedReply("@lead Ship it", to: "ada-lovelace") == "@lead Ship it")
        #expect(NotificationText.addressedReply("Ship it", to: nil) == "Ship it")
        #expect(NotificationText.addressedReply(" \n ", to: "ada-lovelace") == nil)
        #expect(NotificationText.draft("", adding: "@ada Ship it") == "@ada Ship it")
        #expect(NotificationText.draft("Earlier thought\n", adding: "@ada Ship it") == "Earlier thought\n\n@ada Ship it")
    }

    @Test func sentRepliesMarkTheChannelReadThroughThemselves() async {
        var read: [Int] = []
        let reply = NotificationReply(post: { id, content in self.message(content, sequence: 31) },
                                      markRead: { read.append($0) }, pause: {})
        #expect(await reply.send("@ada Ship it") == .sent)
        #expect(read == [31])
    }

    @Test func onlyTransportFailuresRetryOnceWithTheSameID() async {
        var ids: [String] = []
        var pauses = 0
        func reply(_ failures: [any Error]) -> NotificationReply {
            var remaining = failures
            return NotificationReply(post: { id, content in
                ids.append(id)
                if !remaining.isEmpty { throw remaining.removeFirst() }
                return self.message(content, sequence: 31)
            }, markRead: { _ in }, pause: { pauses += 1 })
        }

        #expect(await reply([URLError(.timedOut)]).send("Hi", id: "a") == .sent)
        #expect(ids == ["a", "a"] && pauses == 1)
        #expect(await reply([URLError(.timedOut), ChannelAPIError.duplicateMessage]).send("Hi", id: "b") == .sent)
        #expect(await reply([URLError(.timedOut), URLError(.notConnectedToInternet)]).send("Hi", id: "c") == .failed)
        ids = []
        pauses = 0
        #expect(await reply([ChannelAPIError.http(status: 500, message: "Down")]).send("Hi", id: "d") == .failed)
        #expect(await reply([ChannelAPIError.http(status: 404, message: "Gone")]).send("Hi", id: "e") == .deleted)
        #expect(ids == ["d", "e"] && pauses == 0)
    }

    @Test func notificationsWithdrawOnceTheyStopBeingTrue() {
        func delivered(_ channel: String, _ kind: String, _ sequence: Int, server: String = "s") -> NotificationWithdrawal.Delivered {
            .init(identifier: "\(server):\(channel):\(kind):\(sequence)", serverURL: server, channelID: channel,
                  kind: kind, sequence: sequence)
        }
        let items = [delivered("answered", "request", 11), delivered("waiting", "request", 12),
                     delivered("seen", "completion", 9), delivered("unseen", "completion", 15),
                     delivered("active", "completion", 15), delivered("active", "replyFailed", 0),
                     delivered("waiting", "replyFailed", 0), delivered("deleted", "request", 4),
                     delivered("answered", "request", 11, server: "other")]
        let channels = [channel("answered"), channel("waiting", request: 12), channel("seen"),
                        channel("unseen"), channel("active")]
        #expect(Set(NotificationWithdrawal.stale(items, channels: channels, serverURL: "s", activeChannelID: "active"))
            == ["s:answered:request:11", "s:seen:completion:9", "s:active:completion:15",
                "s:active:replyFailed:0", "s:deleted:request:4"])
    }

    @Test func foregroundPresentationKeepsCompletionsQuiet() {
        #expect(NotificationPresentation.options(kind: "request", isActiveChannel: false) == [.banner, .list, .sound])
        #expect(NotificationPresentation.options(kind: "completion", isActiveChannel: false) == [.list])
        #expect(NotificationPresentation.options(kind: "request", isActiveChannel: true) == [])
        #expect(NotificationPresentation.options(kind: "replyFailed", isActiveChannel: true) == [.banner, .list, .sound])
    }
}

@MainActor
@Suite("Menu bar extra", .timeLimit(.minutes(1)))
struct MenuBarExtraTests {
    private let ada = ChannelAgent(id: "ada", name: "Ada")
    private let nova = ChannelAgent(id: "nova", name: "Nova")
    private let lead = ChannelAgent(id: "lead", name: "Lead")

    private func channel(_ id: String, updated: String = "2026-10-22T08:00:00Z", request: Int? = nil) -> Channel {
        Channel(id: id, name: id.capitalized, model: .init(provider: "test", name: "test"), latestSequence: 20,
                seenThrough: 10, requestSequence: request, updatedAt: updated)
    }

    private func request(_ text: String, sequence: Int = 12, at timestamp: String = "2026-10-22T08:00:00Z",
                         from sender: String = "ada") -> ChannelRequestMessage {
        .init(message: ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: timestamp,
                                      sender: .init(type: "agent", agentId: sender), content: .text(text),
                                      request: true),
              agents: [lead, ada, nova])
    }

    @Test func theSymbolFollowsTheMostUrgentState() {
        let idle = MenuBarStatus([], unreachableHost: nil)
        #expect(idle.state == .idle && idle.symbol == "bubble" && !idle.isActive)
        #expect(idle.accessibilityValue == "No agents working" && idle.emptyText == "No agents are working")

        let offline = MenuBarStatus([], unreachableHost: "studio.local:3100")
        #expect(offline.state == .disconnected && offline.symbol == "bubble" && !offline.isActive)
        #expect(offline.accessibilityValue == "Not connected" && offline.emptyText == "Can't connect to studio.local:3100")

        let working = MenuBarStatus([.init(channel: channel("a"), isWaiting: false, working: [ada])],
                                    unreachableHost: nil)
        #expect(working.state == .working && working.symbol == "ellipsis.bubble" && working.isActive)
        #expect(working.accessibilityValue == "1 agent working" && working.emptyText == nil)

        let waiting = MenuBarStatus([
            .init(channel: channel("a", request: 12), isWaiting: true, working: [lead, ada]),
            .init(channel: channel("b"), isWaiting: false, working: [nova]),
        ], unreachableHost: "studio.local:3100")
        #expect(waiting.state == .waiting && waiting.symbol == "questionmark.bubble.fill" && waiting.isActive)
        #expect(waiting.accessibilityValue == "1 channel waiting for you, 3 agents working")
    }

    @Test func waitingChannelsQuoteTheirRequestNewestFirst() throws {
        let long = "Can you confirm the history review covers paging, search and the outbox before we ship it?"
        let status = MenuBarStatus([
            .init(channel: channel("older", request: 12), isWaiting: true, working: [],
                  request: request("Pick a palette\nfor the icon", at: "2026-10-22T08:00:00Z")),
            .init(channel: channel("newer", request: 14), isWaiting: true, working: [ada],
                  request: request(long, sequence: 14, at: "2026-10-22T09:00:00Z")),
            .init(channel: channel("unknown", updated: "2026-10-22T07:00:00Z", request: 3), isWaiting: true,
                  working: []),
        ], unreachableHost: nil)
        #expect(status.waiting.map(\.id) == ["newer", "older", "unknown"])
        #expect(status.waiting.map(\.sequence) == [14, 12, 3])
        #expect(status.waiting.map(\.agent?.id) == ["ada", "ada", nil])
        #expect(status.waiting[1].subtitle == "Ada needs your reply")
        #expect(status.waiting[1].quote == "Pick a palette\nfor the icon")
        #expect(status.waiting[0].quote == long)
        #expect(status.waiting[2].quote == nil)
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
            .init(channel: channel("quiet"), isWaiting: false, working: []),
            .init(channel: channel("early", updated: "2026-10-22T07:00:00Z"), isWaiting: false, working: [nova]),
            .init(channel: channel("late", updated: "2026-10-22T09:00:00Z"), isWaiting: false, working: [lead, ada]),
        ], unreachableHost: nil)
        #expect(status.working.map(\.id) == ["late", "early"])
        #expect(status.working.map(\.agent?.id) == ["lead", "nova"])
        #expect(status.workingAgents == 3)
    }

    @Test func workingShowsThreeChannelsThenOpensTheWindowForTheRest() {
        let inputs = (0..<8).map { index in
            MenuBarStatus.Input(channel: channel("c\(index)", updated: "2026-10-22T0\(index):00:00Z"),
                                isWaiting: false, working: [ada])
        }
        let section = MenuBarStatus(inputs, unreachableHost: nil).workingSection
        #expect(section.items.map(\.id) == ["c7", "c6", "c5"] && section.overflow == 5)
        #expect(section.items.allSatisfy { $0.agents == [ada] })
        #expect(MenuBarStatus(Array(inputs.prefix(3)), unreachableHost: nil).workingSection.overflow == 0)
    }

    @Test func inboxQuotesFlattenMarkdownWithoutDroppingMentionsOrCuttingAtSixtyCharacters() {
        let text = "@user **Please review** [this proposal](https://example.test). " + String(repeating: "Details. ", count: 30)
        let status = MenuBarStatus([
            .init(channel: channel("one", request: 12), isWaiting: true, working: [], request: request(text))
        ], unreachableHost: nil)
        #expect(status.waiting[0].quote?.hasPrefix("@user Please review this proposal.") == true)
        #expect((status.waiting[0].quote?.count ?? 0) > 200)
        #expect(status.waiting[0].quote?.contains("https://") == false)
    }

    @Test func anOpenInboxKeepsAnsweredRowsAndAppendsNewRequestsWithoutReordering() {
        let first = MenuBarStatus([
            .init(channel: channel("one", request: 12), isWaiting: true, working: [], request: request("First?")),
            .init(channel: channel("two", request: 13), isWaiting: true, working: [],
                  request: request("Second?", sequence: 13)),
        ], unreachableHost: nil)
        var inbox = MenuBarInboxState(status: first)
        let next = MenuBarStatus(waiting: [
            .init(id: "new", name: "New", subtitle: "Needs your reply", agent: ada, sequence: 14, quote: "New?"),
            first.waiting[1],
        ])
        inbox.update(next)
        #expect(inbox.requests.map(\.id) == ["one", "two", "new"])
        #expect(inbox.requests[0].state == .answered)
        #expect(!inbox.requests[0].canReply)
        #expect(inbox.requests[1].canReply)
        #expect(MenuBarInboxState(status: next).requests.map(\.id) == ["new", "two"])
    }

    @Test func aChangedRequestKeepsTheOriginalQuoteAndDisablesItsReply() {
        let item = MenuBarStatus.Item(id: "one", name: "One", subtitle: "", agent: ada, sequence: 12, quote: "First?")
        var inbox = MenuBarInboxState(status: .init(waiting: [item]))
        var newer = item
        newer.sequence = 20
        newer.quote = "Different question?"
        inbox.update(.init(waiting: [newer]))
        #expect(inbox.requests[0].item == item)
        #expect(inbox.requests[0].state == .newerRequest)
        #expect(!inbox.requests[0].canReply)
    }

    @Test func aConfirmedReplyStaysSentUntilTheNextOpening() {
        let item = MenuBarStatus.Item(id: "one", name: "One", subtitle: "", agent: ada, sequence: 12, quote: "First?")
        var inbox = MenuBarInboxState(status: .init(waiting: [item]))
        inbox.confirmed("one")
        inbox.update(.init(waiting: [item]))
        #expect(inbox.requests[0].state == .sent)
        #expect(!inbox.requests[0].canReply)
        inbox.update(.init())
        #expect(inbox.requests[0].state == .sent)
        #expect(MenuBarInboxState(status: .init()).requests.isEmpty)
    }

    @Test func previewArrivalEnablesReplyWithoutInventingARequester() {
        var item = MenuBarStatus.Item(id: "one", name: "One", subtitle: "", sequence: 12)
        var inbox = MenuBarInboxState(status: .init(waiting: [item]))
        #expect(!inbox.requests[0].canReply)
        item.quote = "Question?"
        inbox.update(.init(waiting: [item]))
        #expect(!inbox.requests[0].canReply)
        item.agent = ada
        inbox.update(.init(waiting: [item]))
        #expect(inbox.requests[0].canReply)
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

@Suite("App identity preferences")
final class AppPreferencesMigrationTests {
    private let sourceDomain = "legacy-preferences-\(UUID().uuidString)"
    private let destinationDomain = "desktop-preferences-\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: destinationDomain)! }

    deinit {
        defaults.removePersistentDomain(forName: sourceDomain)
        defaults.removePersistentDomain(forName: destinationDomain)
    }

    private func migrate(bundleIdentifier: String? = AppPreferencesMigration.bundleIdentifier,
                         isSnapshot: Bool = false) {
        AppPreferencesMigration.run(
            isSnapshot: isSnapshot, bundleIdentifier: bundleIdentifier, defaults: defaults,
            sourceDomain: sourceDomain, destinationDomain: destinationDomain
        )
    }

    @Test func theFirstLaunchImportsEveryPersistentAppSetting() {
        let source: [String: Any] = [
            AppConfiguration.serverURLKey: "https://legacy.example/toy-box",
            LaunchChannel.key: ["https://legacy.example/toy-box": "studio"],
            "appearance": "dark", "textScale": 1.25, MenuBarVisibility.key: "never",
            "notificationsEnabled": true, "requestNotifications": false,
            "completionNotifications": false, TranscriptIntelligenceSettings.summarizesNewMessages: false,
            TranscriptIntelligenceSettings.describesImages: true,
        ]
        defaults.setPersistentDomain(source, forName: sourceDomain)
        migrate()
        let imported = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        var expected = source
        expected[AppPreferencesMigration.completionKey] = true
        expected[AppPreferencesMigration.notificationOptInKey] = true
        #expect(NSDictionary(dictionary: imported).isEqual(to: expected))
        #expect(defaults.bool(forKey: AppPreferencesMigration.completionKey))
        #expect(LaunchChannel(defaults: defaults).channelID(serverURL: "https://legacy.example/toy-box") == "studio")
        #expect(NSDictionary(dictionary: source).isEqual(to: defaults.persistentDomain(forName: sourceDomain) ?? [:]))
    }

    @Test func existingDestinationKeysAlwaysWinIncludingFalseAndEmptyValues() {
        defaults.setPersistentDomain([
            "serverURL": "https://legacy.example", "appearance": "dark",
            "notificationsEnabled": true, "textScale": 1.25,
            LaunchChannel.key: ["https://legacy.example": "old"],
        ], forName: sourceDomain)
        let destination: [String: Any] = [
            "serverURL": "", "notificationsEnabled": false, "textScale": 0.0,
            LaunchChannel.key: ["https://new.example": "new"],
        ]
        defaults.setPersistentDomain(destination, forName: destinationDomain)
        migrate()
        let imported = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        var expected = destination
        expected["appearance"] = "dark"
        expected[AppPreferencesMigration.completionKey] = true
        #expect(NSDictionary(dictionary: imported).isEqual(to: expected))
    }

    @Test func registeredDefaultsDoNotHideLegacySettings() {
        defaults.register(defaults: ["registeredMigrationSetting": "fallback"])
        defaults.setPersistentDomain(["registeredMigrationSetting": "legacy"], forName: sourceDomain)
        migrate()
        #expect(defaults.string(forKey: "registeredMigrationSetting") == "legacy")
    }

    @Test func aCompletedImportNeverRunsAgainEvenWhenAnImportedKeyIsRemoved() {
        defaults.setPersistentDomain(["appearance": "dark"], forName: sourceDomain)
        migrate()
        defaults.removeObject(forKey: "appearance")
        defaults.setPersistentDomain(["appearance": "light", "textScale": 2.0], forName: sourceDomain)
        migrate()
        #expect(defaults.object(forKey: "appearance") == nil)
        #expect(defaults.object(forKey: "textScale") == nil)
    }

    @Test func anAbsentLegacyDomainStillCompletesTheOneTimeImport() {
        migrate()
        #expect(defaults.bool(forKey: AppPreferencesMigration.completionKey))
        defaults.setPersistentDomain(["appearance": "dark"], forName: sourceDomain)
        migrate()
        #expect(defaults.object(forKey: "appearance") == nil)
    }

    @Test(arguments: [
        String?.none, AppPreferencesMigration.legacyDomain,
        AppPreferencesMigration.bundleIdentifier + ".test",
        AppPreferencesMigration.bundleIdentifier + ".benchmark",
        AppPreferencesMigration.bundleIdentifier + ".updatetest",
    ])
    func otherBundleIdentitiesNeverReadOrMarkTheMigration(_ bundleIdentifier: String?) {
        defaults.setPersistentDomain(["appearance": "dark"], forName: sourceDomain)
        migrate(bundleIdentifier: bundleIdentifier)
        #expect(defaults.persistentDomain(forName: destinationDomain) == nil)
    }

    @Test func snapshotsLeaveMigrationPendingForTheFirstOrdinaryLaunch() {
        defaults.setPersistentDomain(["appearance": "dark"], forName: sourceDomain)
        migrate(isSnapshot: true)
        #expect(defaults.persistentDomain(forName: destinationDomain) == nil)
        migrate()
        #expect(defaults.string(forKey: "appearance") == "dark")
    }

    @Test(arguments: [Bool?.none, false, true])
    func onlyAnImportedNotificationOptInIsConsumedOnce(_ enabled: Bool?) {
        var source: [String: Any] = [:]
        if let enabled { source["notificationsEnabled"] = enabled }
        defaults.setPersistentDomain(source, forName: sourceDomain)
        migrate()
        #expect(takeNotificationOptIn() == (enabled == true))
        #expect(!takeNotificationOptIn())
    }

    @Test(arguments: [false, true])
    func existingNotificationPreferencesDoNotPrompt(_ enabled: Bool) {
        defaults.setPersistentDomain(["notificationsEnabled": true], forName: sourceDomain)
        defaults.set(enabled, forKey: "notificationsEnabled")
        migrate()
        #expect(!takeNotificationOptIn())
        #expect(defaults.bool(forKey: "notificationsEnabled") == enabled)
    }

    @Test func aBackgroundImportWaitsForTheRealAppWithoutBeingConsumedByTestsOrSnapshots() {
        defaults.setPersistentDomain(["notificationsEnabled": true], forName: sourceDomain)
        migrate()
        #expect(!takeNotificationOptIn(isSnapshot: true))
        #expect(!takeNotificationOptIn(bundleIdentifier: AppPreferencesMigration.bundleIdentifier + ".test"))
        #expect(takeNotificationOptIn())
        #expect(!takeNotificationOptIn())
    }

    @Test func turningNotificationsOffBeforeTheFirstActiveWindowCancelsThePrompt() {
        defaults.setPersistentDomain(["notificationsEnabled": true], forName: sourceDomain)
        migrate()
        defaults.set(false, forKey: "notificationsEnabled")
        #expect(!takeNotificationOptIn())
        #expect(defaults.object(forKey: AppPreferencesMigration.notificationOptInKey) == nil)
    }

    private func takeNotificationOptIn(bundleIdentifier: String? = AppPreferencesMigration.bundleIdentifier,
                                      isSnapshot: Bool = false) -> Bool {
        AppPreferencesMigration.takeNotificationOptIn(
            isSnapshot: isSnapshot, bundleIdentifier: bundleIdentifier, defaults: defaults
        )
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
        // The 12-point inset, 438 points of semibold text, 4 points of spacing and the 11-point chevron.
        #expect(abs(ChannelTitleFit.idealWidth(of: long) - 465) <= 2)
        #expect(ChannelTitleFit.idealWidth(of: "Studio demo") < 130)
    }

    @Test func theNarrowestWindowKeepsEveryControl() {
        // The title starts 8 points past the 248-point sidebar and ends 24 points, plus the item's
        // inset, before the trailing capsule at 634.
        let room = ChannelTitleFit.room(detail: Span(minX: 248, maxX: 760), windowWidth: 760)
        #expect(room == 350)
        #expect(ChannelTitleFit.maxWidth(idealWidth: 465, room: room) == 350)
    }

    @Test func aCollapsedSidebarStartsTheTitleAfterTheSidebarButton() {
        #expect(ChannelTitleFit.room(detail: Span(minX: 0, maxX: 760), windowWidth: 760) == 426)
        // The sidebar's collapse animation passes through widths narrower than the buttons it covers.
        #expect(ChannelTitleFit.room(detail: Span(minX: 120, maxX: 760), windowWidth: 760) == 426)
    }

    @Test func anOpenInspectorStopsTheTitleShortOfIt() {
        let room = ChannelTitleFit.room(detail: Span(minX: 248, maxX: 688), windowWidth: 1000)
        #expect(room == 420)
        #expect(ChannelTitleFit.room(detail: Span(minX: 248, maxX: 968), windowWidth: 1280) == 700)
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
        #expect(fit.maxWidth == 350)
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
