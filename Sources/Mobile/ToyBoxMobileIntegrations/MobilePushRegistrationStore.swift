import ToyBoxKit
import Foundation

public struct MobilePushRegistration: Codable, Equatable, Sendable {
    public var serverURL: String
    public var registrationID: String
}

/// The phone's push registration on each server, which the app, its notification extension and its
/// widget share, so a push names its server by its registration.
@MainActor
public final class MobilePushRegistrationStore {
    public static let fileName = "push-registration.json"
    /// One per server, in the order they were added.
    public private(set) var registrations: [MobilePushRegistration]
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

    /// Reads the saved registrations. A file from before the phone had several servers holds one, which
    /// stays the first with its ID.
    public init(directory: URL? = nil) throws {
        let directory = try directory ?? MobileSharedContainer.url()
        file = directory.appendingPathComponent(Self.fileName)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            registrations = []
            return
        }
        let decoder = JSONDecoder()
        let saved = try (try? decoder.decode([MobilePushRegistration].self, from: data))
            ?? [decoder.decode(MobilePushRegistration.self, from: data)]
        guard saved.allSatisfy({ registration in
            ChannelTarget.normalizedServer(registration.serverURL) != nil
                && UUID(uuidString: registration.registrationID) != nil
        }) else { throw Failure.invalidRegistration }
        registrations = saved
    }

    /// A server's registration, however its address is spelled.
    public func registration(for serverURL: String) -> MobilePushRegistration? {
        guard let server = ChannelTarget.normalizedServer(serverURL) else { return nil }
        return registrations.first { ChannelTarget.normalizedServer($0.serverURL) == server }
    }

    public func registration(id: String) -> MobilePushRegistration? {
        registrations.first { $0.registrationID == id }
    }

    /// The server's registration, keeping its ID through another spelling of its address. A server
    /// without one gets a new ID, even one it had before.
    @discardableResult
    public func register(serverURL: String) throws -> MobilePushRegistration {
        guard ChannelTarget.normalizedServer(serverURL) != nil else { throw Failure.invalidServer }
        var next = registrations
        let registration: MobilePushRegistration
        if let existing = self.registration(for: serverURL),
           let index = next.firstIndex(of: existing) {
            if existing.serverURL == serverURL { return existing }
            next[index].serverURL = serverURL
            registration = next[index]
        } else {
            registration = MobilePushRegistration(serverURL: serverURL, registrationID: UUID().uuidString)
            next.append(registration)
        }
        try save(next)
        return registration
    }

    /// Forgets a server's registration, as removing the server does.
    public func remove(registrationID: String) throws {
        guard registrations.contains(where: { $0.registrationID == registrationID }) else { return }
        try save(registrations.filter { $0.registrationID != registrationID })
    }

    private func save(_ next: [MobilePushRegistration]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        registrations = next
    }
}
