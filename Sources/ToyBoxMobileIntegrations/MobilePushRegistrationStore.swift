import ChannelKit
import Foundation

public struct MobilePushRegistration: Codable, Equatable, Sendable {
    public var serverURL: String
    public var registrationID: String
}

@MainActor
public final class MobilePushRegistrationStore {
    public static let fileName = "push-registration.json"
    public private(set) var current: MobilePushRegistration?
    private let file: URL

    public enum Failure: LocalizedError {
        case invalidServer, invalidRegistration

        public var errorDescription: String? {
            switch self {
            case .invalidServer: "Enter an HTTP or HTTPS server URL."
            case .invalidRegistration: "Toy Box's saved notification registration is invalid."
            }
        }
    }

    public init(directory: URL? = nil) throws {
        let directory = try directory ?? MobileSharedContainer.url()
        file = directory.appendingPathComponent(Self.fileName)
        do {
            let registration = try JSONDecoder().decode(MobilePushRegistration.self, from: Data(contentsOf: file))
            guard ChannelWaitingRequest.normalizedServer(registration.serverURL) != nil,
                  UUID(uuidString: registration.registrationID) != nil else { throw Failure.invalidRegistration }
            current = registration
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            current = nil
        }
    }

    @discardableResult
    public func select(serverURL: String) throws -> MobilePushRegistration {
        guard let server = ChannelWaitingRequest.normalizedServer(serverURL) else { throw Failure.invalidServer }
        var registration: MobilePushRegistration
        if let current, ChannelWaitingRequest.normalizedServer(current.serverURL) == server {
            if current.serverURL == serverURL { return current }
            registration = current
            registration.serverURL = serverURL
        } else {
            registration = MobilePushRegistration(serverURL: serverURL, registrationID: UUID().uuidString)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(registration).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        current = registration
        return registration
    }
}
