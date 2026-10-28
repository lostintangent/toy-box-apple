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
