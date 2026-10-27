import ChannelClient
import SwiftUI
import ToyBoxUI

typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct ToyBoxMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance: AppAppearance = .system

    var body: some Scene {
        WindowGroup {
            RootView()
                #if DEBUG && targetEnvironment(simulator)
                .mobileFoundationProofIfRequested()
                #endif
                .environment(appDelegate.model)
                .environment(appDelegate.model.following)
                .preferredColorScheme(appearance.colorScheme)
                .task { await appDelegate.model.startIntegrations() }
                #if DEBUG
                .task { await MobileAutomation.runIfRequested() }
                #endif
        }
        .commands { ChannelCommands() }
    }
}
