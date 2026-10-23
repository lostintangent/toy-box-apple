import ChannelKit
import CryptoKit
import Foundation

public enum ChannelSendPhase: String, Codable, Equatable, Sendable {
    case sending
    case notSent
    case deliveryNotConfirmed
    case confirmed

    public var label: String {
        switch self {
        case .sending: "Sending"
        case .notSent: "Not sent"
        case .deliveryNotConfirmed: "Delivery not confirmed"
        case .confirmed: "Sent"
        }
    }
}

public struct ChannelSendAttempt: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var content: String
    public var attachments: [ChannelAttachment]
    public var timestamp: String
    public var phase: ChannelSendPhase
    public var error: String?

    public var message: ChannelMessage {
        .init(id: id, sequence: 0, timestamp: timestamp, sender: .user, content: .text(content),
              attachments: attachments.isEmpty ? nil : attachments)
    }

    public var canRetry: Bool { phase == .notSent || phase == .deliveryNotConfirmed }
}

public struct ChannelSendFailure: Equatable, Identifiable, Sendable {
    public let id: String
    public let messageId: String
    public let phase: ChannelSendPhase
    public let error: String
}

public enum ChannelSendResult: Equatable, Sendable {
    case committed(ChannelMessage)
    case alreadyAccepted(id: String)
}

public actor ChannelSendJournal {
    public static let shared = ChannelSendJournal(
        directory: URL.applicationSupportDirectory.appending(path: "ToyBoxChannels/Outbox", directoryHint: .isDirectory)
    )

    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func load(server: URL, channelId: String) throws -> [ChannelSendAttempt] {
        let url = file(server: server, channelId: channelId)
        do {
            return try JSONDecoder().decode([ChannelSendAttempt].self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    public func save(_ attempts: [ChannelSendAttempt], server: URL, channelId: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let url = file(server: server, channelId: channelId)
        try JSONEncoder().encode(attempts).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func file(server: URL, channelId: String) -> URL {
        let key = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "\n" + channelId
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
}
