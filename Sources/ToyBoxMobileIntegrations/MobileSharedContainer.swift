import Foundation

public enum MobileSharedContainer {
    public static let identifier = "group.dev.toybox.mobile"

    public enum Failure: LocalizedError {
        case unavailable

        public var errorDescription: String? { "Toy Box cannot access its shared app container." }
    }

    public static func url() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier) else { throw Failure.unavailable }
        return url
    }
}

#if DEBUG && targetEnvironment(simulator)
public enum MobileFoundationProbe {
    public static func record(_ component: String) throws -> String {
        let container = try MobileSharedContainer.url()
        let marker = try String(contentsOf: container.appending(path: "foundation-marker.txt"), encoding: .utf8)
        try Data(marker.utf8).write(to: container.appending(path: "foundation-\(component).txt"), options: .atomic)
        return marker
    }
}
#endif
