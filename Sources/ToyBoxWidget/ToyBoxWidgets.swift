import AppIntents
import SwiftUI
import ToyBoxControlIntents
import WidgetKit

@main
struct ToyBoxWidgets: WidgetBundle {
    var body: some Widget {
        NeedsYouWidget()
        QuickSendControl()
        NeedsYouControl()
    }

}

struct WidgetControlIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [ToyBoxControlIntentsPackage.self] }
}
