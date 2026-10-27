import ChannelClient
import SwiftUI
import ToyBoxUI

typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct ToyBoxMobileApp: App {
    @ViewState private var model = AppModel()
    @AppStorage("appearance") private var appearance: AppAppearance = .system

    var body: some Scene {
        WindowGroup {
            RootView()
                #if DEBUG && targetEnvironment(simulator)
                .mobileFoundationProofIfRequested()
                #endif
                .environment(model)
                .preferredColorScheme(appearance.colorScheme)
                #if DEBUG
                .task { await MobileAutomation.runIfRequested() }
                #endif
        }
        .commands { ChannelCommands() }
    }
}
