import Foundation

public struct ChannelArtifactShare: Equatable, Sendable {
    public let actor: ChannelMessageSender?
    public let sharedAt: String
    public let sequence: Int

    public init(actor: ChannelMessageSender?, sharedAt: String, sequence: Int) {
        self.actor = actor
        self.sharedAt = sharedAt
        self.sequence = sequence
    }
}

public func channelArtifactShares(_ messages: [ChannelMessage]) -> [String: ChannelArtifactShare] {
    var shares: [String: ChannelArtifactShare] = [:]
    for message in messages {
        guard message.isSystem, let system = message.system,
              system.type == "artifact_shared", let artifact = system.artifact else { continue }
        let id = artifact.file.id
        if let existing = shares[id], existing.sequence >= message.sequence { continue }
        shares[id] = .init(actor: system.actor, sharedAt: message.timestamp, sequence: message.sequence)
    }
    return shares
}
