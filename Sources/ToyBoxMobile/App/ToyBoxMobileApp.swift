import ChannelClient
import SwiftUI
import ToyBoxUI

typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct ToyBoxMobileApp: App {
    @ViewState private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                #if DEBUG
                .task { await MobileAutomation.runIfRequested() }
                #endif
        }
        .commands { ChannelCommands() }
    }
}
