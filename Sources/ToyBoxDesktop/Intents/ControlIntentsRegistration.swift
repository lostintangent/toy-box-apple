import AppIntents
import Foundation
import ToyBoxControlIntents

struct DesktopControlIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [ToyBoxControlIntentsPackage.self] }
}

extension ToyBoxControlsContext {
    @MainActor
    static func register(_ model: AppModel) {
        let context = makeRouter { [weak model] url in
            try model?.openWidgetURL(url) == true
        }
        AppDependencyManager.shared.add(dependency: context)
    }

    @MainActor
    static func makeRouter(_ openURL: @escaping @MainActor (URL) throws -> Bool) -> ToyBoxControlsContext {
        ToyBoxControlsContext { url in
            AppDelegate.receivedOpenEvent = true
            guard try openURL(url) else { throw ControlRouteError.unavailable }
        }
    }
}

private enum ControlRouteError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Toy Box could not open this control." }
}
