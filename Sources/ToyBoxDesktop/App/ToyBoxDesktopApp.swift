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

    init() {
        do {
            let options = try LaunchOptions.parse(Array(ProcessInfo.processInfo.arguments.dropFirst()))
            AppDelegate.isSnapshot = options.isSnapshot
            if options.isSnapshot {
                var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                arguments["ApplePersistenceIgnoreState"] = true
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            }
            let model = AppModel(launchOptions: options)
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
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(model.launchOptions.isSnapshot ? .disabled : .automatic)
        .windowStyle(.automatic)
        .commands { ChannelCommands(model: model) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard !model.launchOptions.isSnapshot else { return }
            appDelegate.openChannelWindow = { openWindow(id: "channels") }
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
    var openChannelWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
