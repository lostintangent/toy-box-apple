import AppIntents
import Foundation
import ToyBoxControlIntents

struct DesktopControlIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [ToyBoxControlIntentsPackage.self] }
}

extension ToyBoxControlsContext {
    @MainActor
    static func register(_ model: AppModel) {
        let context = ToyBoxControlsContext { [weak model] url in
            guard let model, try model.openWidgetURL(url) else { throw ControlRouteError.unavailable }
        }
        AppDependencyManager.shared.add(dependency: context)
    }
}

private enum ControlRouteError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Toy Box could not open this control." }
}
