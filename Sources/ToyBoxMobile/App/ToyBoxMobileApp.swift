import ChannelClient
import SwiftUI

@main
struct ToyBoxMobileApp: App {
    var body: some Scene {
        WindowGroup {
            ContentUnavailableView("Toy Box", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("iPhone companion coming soon."))
        }
    }
}
