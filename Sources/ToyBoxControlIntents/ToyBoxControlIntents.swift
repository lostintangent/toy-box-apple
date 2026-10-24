import AppIntents
import Foundation

public struct ToyBoxControlIntentsPackage: AppIntentsPackage {}

public enum ToyBoxControlDestination: String, AppEnum {
    case quickSend
    case needsYou

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Toy Box control")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .quickSend: "Quick Send",
        .needsYou: "Needs You",
    ]

    public var url: URL {
        switch self {
        case .quickSend: URL(string: "toybox-desktop://quick-send")!
        case .needsYou: URL(string: "toybox-desktop://inbox")!
        }
    }
}

public struct OpenToyBoxControlIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Toy Box Control"
    public static let supportedModes: IntentModes = .foreground(.immediate)
    public static let isDiscoverable = false

    @Parameter(title: "Control")
    public var target: ToyBoxControlDestination

    @AppDependency var context: ToyBoxControlsContext

    public init() {}

    public init(target: ToyBoxControlDestination) {
        self.target = target
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        try context.open(target.url)
        return .result()
    }
}

@MainActor
public final class ToyBoxControlsContext {
    private let openURL: @MainActor (URL) throws -> Void

    public init(openURL: @escaping @MainActor (URL) throws -> Void) {
        self.openURL = openURL
    }

    public func open(_ url: URL) throws {
        try openURL(url)
    }
}
