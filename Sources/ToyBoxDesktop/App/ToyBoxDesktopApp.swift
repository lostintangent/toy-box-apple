import AppKit
import SwiftUI

// The macOS 27 CLT SDK exports a same-named macro without its plugin. Keep the property wrapper.
typealias ViewState<Value> = SwiftUI.State<Value>

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
            AppPreferencesMigration.run(isSnapshot: options.isSnapshot)
            AppDelegate.isSnapshot = options.isSnapshot
            AppDelegate.launchedInBackground = NSRunningApplication.current.activationPolicy == .prohibited
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
            ChannelIntentsContext.register(model)
            _model = ViewState(wrappedValue: model)
        } catch {
            FileHandle.standardError.write(Data("Invalid launch arguments: \(error.localizedDescription)\n".utf8))
            exit(64)
        }
    }

    var body: some Scene {
        WindowGroup("Channels", id: "channels", for: ChannelWindowValue.self) { $value in
            root(channelID: value?.channelID ?? model.launchOptions.channelID)
        }
        .defaultSize(width: CGFloat(model.launchOptions.width), height: CGFloat(model.launchOptions.height))
        .defaultLaunchBehavior(AppDelegate.launchedInBackground ? .suppressed : .presented)
        .restorationBehavior(model.launchOptions.isSnapshot ? .disabled : .automatic)
        .windowStyle(.automatic)
        .commands { ChannelCommands(model: model) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.openChannelWindow = { openWindow(value: ChannelWindowValue(channelID: $0)) }
            model.openMainWindow = { openWindow(id: "channels") }
            guard !model.launchOptions.isSnapshot else { return }
            appDelegate.openChannelWindow = { openWindow(id: "channels") }
            if phase != .background { appDelegate.comeForward() }
            guard !appDelegate.isInBackground else { return }
            if phase == .active {
                Task { await model.authorizeImportedNotificationsIfNeeded() }
            }
            guard !didCheckStartupWindow || phase == .active else { return }
            didCheckStartupWindow = true
            DispatchQueue.main.async {
                if !NSApp.windows.contains(where: { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain }) {
                    openWindow(id: "channels")
                }
            }
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
    static var isSnapshot = false
    /// Siri and Shortcuts launch the app with activation prohibited to run a background intent,
    /// such as Catch Me Up or Send Message. Until something brings it forward, it opens no window
    /// and stays out of the Dock, so the system quits it once the intent finishes.
    static var launchedInBackground = false
    private var cameForward = false
    var isInBackground: Bool { Self.launchedInBackground && !cameForward }
    var openChannelWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An accessory app stays out of the Dock but can still be activated, so a reopen, the menu
        // bar extra or a notification can bring it forward.
        NSApplication.shared.setActivationPolicy(isInBackground ? .accessory : .regular)
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
        !Self.isSnapshot
    }

    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        !Self.isSnapshot
    }
}
