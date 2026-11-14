import ToyBoxClient
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

extension ChannelOutbox {
    /// The phone's outbox, saved in the app group so the app shows and delivers what the share
    /// extension sends. The extension's sends once, since it ends before it could retry.
    public static func mobile(sendsOnce: Bool = false) -> ChannelOutbox {
        let folder = (try? MobileSharedContainer.url().appending(path: "Sending", directoryHint: .isDirectory))
            ?? ChannelOutbox.defaultFolder
        return ChannelOutbox(folder: folder, sendsOnce: sendsOnce)
    }
}
