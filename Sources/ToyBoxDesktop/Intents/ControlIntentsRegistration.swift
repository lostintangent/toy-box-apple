import AppIntents
import Foundation
import ToyBoxControlIntents

struct DesktopControlIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [ToyBoxControlIntentsPackage.self] }
}

extension ControlRouter {
    @MainActor
    static func register(_ model: AppModel, delegate: AppDelegate) {
        let context = makeRouter(delegate: delegate) { [weak model] url in
            try model?.openWidgetURL(url) == true
        }
        AppDependencyManager.shared.add(dependency: context)
    }

    @MainActor
    static func makeRouter(delegate: AppDelegate,
                           _ openURL: @escaping @MainActor (URL) throws -> Bool) -> ControlRouter {
        ControlRouter { url in
            delegate.receivedOpenEvent = true
            guard try openURL(url) else { throw ControlRouteError.unavailable }
        }
    }
}

private enum ControlRouteError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Toy Box could not open this control." }
}
