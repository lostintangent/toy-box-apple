import Foundation

extension ChannelArtifact {
    public struct Share: Equatable, Sendable {
        public let actor: ChannelMessageSender?
        public let sharedAt: String
        public let sequence: Int

        public init(actor: ChannelMessageSender?, sharedAt: String, sequence: Int) {
            self.actor = actor
            self.sharedAt = sharedAt
            self.sequence = sequence
        }

        /// The latest share of each artifact, keyed by its file id.
        public static func shares(in messages: [ChannelMessage]) -> [String: Share] {
            var shares: [String: Share] = [:]
            for message in messages {
                guard message.isSystem, let system = message.system,
                      system.type == "artifact_shared", let artifact = system.artifact else { continue }
                let id = artifact.file.id
                if let existing = shares[id], existing.sequence >= message.sequence { continue }
                shares[id] = .init(actor: system.actor, sharedAt: message.timestamp, sequence: message.sequence)
            }
            return shares
        }
    }
}
