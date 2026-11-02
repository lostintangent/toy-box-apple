import AppKit
import SwiftUI
import ToyBoxControlIntents
import ToyBoxUI

@main
struct ToyBoxDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var model: AppModel
    @ViewState private var didCheckStartupWindow = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage("textScale") private var textScale = 1.0
    @AppStorage(MenuBarVisibility.key) private var menuBarVisibility: MenuBarVisibility = .whenActive

    init() {
        do {
            let options = try LaunchOptions.parse(Array(ProcessInfo.processInfo.arguments.dropFirst()),
                                                 environment: ProcessInfo.processInfo.environment)
            let delegate = _appDelegate.wrappedValue
            delegate.isSnapshot = options.isSnapshot
            delegate.launchedInBackground = NSRunningApplication.current.activationPolicy == .prohibited
            delegate.detectLoginLaunch()
            if options.isSnapshot || options.quickSendValidation != nil {
                var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                if options.isSnapshot { arguments["ApplePersistenceIgnoreState"] = true }
                if let validation = options.quickSendValidation {
                    arguments[QuickSendValidation.argumentKey] = validation.rawValue
                }
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            }
            let model = AppModel(launchOptions: options)
            model.quickSend.setContent(
                QuickSendView(lastUsedChannel: { model.lastUsedChannelID }).environment(model)
            )
            delegate.quickSendIntake = model.quickSend.isEnabled ? QuickSendIntake { prefill in
                guard model.quickSend.isEnabled else { throw QuickSendIntake.IntakeError.unavailable }
                model.quickSend.present(prefill: prefill)
            } : nil
            ChannelIntentsContext.register(model)
            ControlRouter.register(model, delegate: delegate)
            delegate.widgetURLHandler = { try model.openWidgetURL($0) }
            delegate.dockMenuProvider = { model.makeDockMenu() }
            _model = ViewState(wrappedValue: model)
        } catch {
            FileHandle.standardError.write(Data("Invalid launch arguments: \(error.localizedDescription)\n".utf8))
            exit(64)
        }
    }

    var body: some Scene {
        let _ = configureWindowActions()
        WindowGroup("Channels", id: "channels", for: ChannelWindowValue.self) { $value in
            root(channelID: value?.channelID ?? model.launchOptions.channelID)
        }
        .defaultSize(width: CGFloat(model.launchOptions.width), height: CGFloat(model.launchOptions.height))
        // Wait for the open-application event before deciding whether to open a first window.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(model.launchOptions.isSnapshot || appDelegate.launchedAtLogin ? .disabled : .automatic)
        .windowStyle(.automatic)
        .commands { ChannelCommands(model: model) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            updateStartupWindow(phase: phase)
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(appearance.colorScheme)
        }

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarInbox().environment(model)
                .environment(\.channelTextScale, textScale)
                .preferredColorScheme(appearance.colorScheme)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: menuBarVisibility, initial: true) { _, visibility in
            model.menuBar.visibility = visibility
        }
    }

    private var menuBarInserted: Binding<Bool> {
        Binding(get: { model.showsMenuBarExtra && model.menuBar.isInserted }, set: { _ in })
    }

    private func configureWindowActions() {
        model.openChannelWindow = { openWindow(value: ChannelWindowValue(channelID: $0)) }
        model.openMainWindow = { openWindow(id: "channels") }
        appDelegate.openChannelWindow = { openWindow(id: "channels") }
        appDelegate.openStartupWindow = { updateStartupWindow(phase: scenePhase) }
    }

    private func updateStartupWindow(phase: ScenePhase) {
        guard appDelegate.didFinishLaunching else { return }
        if !model.launchOptions.isSnapshot, phase != .background { appDelegate.comeForward() }
        guard !AppLoginLaunch.suppressesStartupWindow(
            login: appDelegate.launchedAtLogin, backgroundIntent: appDelegate.launchedInBackground
        ) else { return }
        guard !didCheckStartupWindow || phase == .active else { return }
        didCheckStartupWindow = true
        DispatchQueue.main.async {
            if AppLoginLaunch.shouldOpenStartupWindow(
                login: appDelegate.launchedAtLogin, backgroundIntent: appDelegate.launchedInBackground,
                receivedContent: appDelegate.receivedOpenEvent || appDelegate.quickSendIntake?.hasReceivedContent == true,
                hasMainWindow: NSApp.windows.contains(where: { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain })
            ) {
                openWindow(id: "channels")
            }
        }
    }

    private func root(channelID: String?) -> some View {
        RootView(initialChannelID: channelID)
            .environment(model)
            .environment(\.channelTextScale, model.launchOptions.isSnapshot ? 1 : textScale)
            .environment(\.windowSnapshot, model.snapshot)
            .preferredColorScheme((model.launchOptions.appearance ?? appearance).colorScheme)
    }
}

struct ChannelWindowValue: Codable, Hashable {
    let channelID: String
    let windowID: UUID

    init(channelID: String) {
        self.channelID = channelID
        windowID = UUID()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var isSnapshot = false
    /// Siri and Shortcuts launch the app with activation prohibited to run a background intent,
    /// such as Catch Me Up or Send Message. Until something brings it forward, it opens no window
    /// and stays out of the Dock, so the system quits it once the intent finishes.
    var launchedInBackground = false
    private(set) var launchedAtLogin = false
    var receivedOpenEvent = false
    var quickSendIntake: QuickSendIntake?
    var widgetURLHandler: ((URL) throws -> Bool)?
    var dockMenuProvider: (() -> NSMenu)?
    private var cameForward = false
    var isInBackground: Bool { launchedInBackground && !launchedAtLogin && !cameForward }
    var openChannelWindow: (() -> Void)?
    var openStartupWindow: (() -> Void)?
    private(set) var didFinishLaunching = false

    func detectLoginLaunch() {
        guard !isSnapshot, AppLoginLaunch.isLoginEvent(NSAppleEventManager.shared().currentAppleEvent) else { return }
        launchedAtLogin = true
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["ApplePersistenceIgnoreState"] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        detectLoginLaunch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        detectLoginLaunch()
        // An accessory app stays out of the Dock but can still be activated, so a reopen, the menu
        // bar extra or a notification can bring it forward.
        NSApplication.shared.setActivationPolicy(AppLoginLaunch.activationPolicy(
            login: launchedAtLogin, backgroundIntent: isInBackground))
        NSApplication.shared.servicesProvider = quickSendIntake
        didFinishLaunching = true
        DispatchQueue.main.async { self.openStartupWindow?() }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenuProvider?()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        detectLoginLaunch()
        return !AppLoginLaunch.suppressesStartupWindow(login: launchedAtLogin, backgroundIntent: launchedInBackground)
            && !receivedOpenEvent && quickSendIntake?.hasReceivedContent != true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receivedOpenEvent = true
        do {
            guard let intake = quickSendIntake else { throw QuickSendIntake.IntakeError.unavailable }
            try intake.openFiles(filenames)
            sender.reply(toOpenOrPrint: .success)
        } catch {
            sender.reply(toOpenOrPrint: .failure)
            sender.presentError(error)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedOpenEvent = true
        for url in urls {
            do {
                if try widgetURLHandler?(url) == true { continue }
                guard let intake = quickSendIntake else { throw QuickSendIntake.IntakeError.unavailable }
                try intake.openSharedURL(url)
            } catch {
                application.presentError(error)
            }
        }
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        comeForward()
    }

    /// Makes a background launch an ordinary app once it's activated or shows a window.
    func comeForward() {
        guard isInBackground else { return }
        cameForward = true
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = sender.windows.first(where: { $0.isMiniaturized && $0.canBecomeMain }) {
                window.deminiaturize(nil)
            } else {
                openChannelWindow?()
            }
        }
        return true
    }

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
        !isSnapshot
    }

    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        detectLoginLaunch()
        return !isSnapshot && !launchedAtLogin
    }
}
