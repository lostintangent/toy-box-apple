import ChannelClient
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
    /// extension sends. The extension's hands every send to iOS at once, since it ends before it
    /// could finish one, and the app takes iOS's answer.
    public static func mobile(handsOff: Bool = false) -> ChannelOutbox {
        let folder = (try? MobileSharedContainer.url().appending(path: "Sending", directoryHint: .isDirectory))
            ?? ChannelOutbox.defaultFolder
        return ChannelOutbox(folder: folder, background: .init(
            session: handsOff ? "dev.toybox.mobile.outbox.share" : "dev.toybox.mobile.outbox",
            sharedContainer: MobileSharedContainer.identifier, handsOff: handsOff))
    }
}
