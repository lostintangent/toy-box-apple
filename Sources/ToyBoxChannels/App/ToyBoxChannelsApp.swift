import AppKit
import SwiftUI

// The macOS 27 CLT SDK exports a same-named macro without its plugin. Keep the property wrapper.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct ToyBoxChannelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 840)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }
}
