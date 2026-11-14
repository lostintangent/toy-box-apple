import ToyBoxKit
import Foundation

/// What New Channel and Edit Channel hold while you type, and the one request they send.
public struct ChannelForm: Sendable {
    /// The channel being edited, or nil for a new one.
    public let channel: ChannelDetails?
    public var name: String
    public var purpose: String
    /// Only a new channel chooses its directory.
    public var directory: String
    public var model: ModelConfiguration?

    public init(_ channel: ChannelDetails? = nil) {
        self.channel = channel
        name = channel?.name ?? ""
        purpose = channel?.purpose ?? ""
        directory = channel?.directory ?? ""
        model = channel?.model
    }

    private var nextName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nextPurpose: String { purpose.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nextDirectory: String { directory.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var nameViolation: String? { Channel.nameError(nextName) }
    public var purposeViolation: String? { Channel.purposeError(nextPurpose) }
    public var directoryViolation: String? { channel == nil ? Channel.directoryError(nextDirectory) : nil }

    /// An empty name or a missing lead model only disables saving, since the field's prompt and the
    /// model section already say why.
    public var isSubmittable: Bool {
        guard !nextName.isEmpty, model != nil,
              nameViolation == nil, purposeViolation == nil, directoryViolation == nil else { return false }
        guard let channel else { return true }
        return nextName != channel.name || nextPurpose != (channel.purpose ?? "") || model != channel.model
    }

    /// Creates the channel, or sends only what changed.
    public func submit(to api: ChannelAPI) async throws -> Channel {
        guard let model else { throw ChannelAPIError.invalidMessage("Choose a lead model.") }
        guard let channel else {
            return try await api.createChannel(.init(
                name: nextName, purpose: nextPurpose.isEmpty ? nil : nextPurpose,
                directory: nextDirectory.isEmpty ? nil : nextDirectory, model: model))
        }
        return try await api.editChannel(id: channel.id, changes: .init(
            name: nextName == channel.name ? nil : nextName,
            purpose: nextPurpose == (channel.purpose ?? "") ? nil : nextPurpose.isEmpty ? .clear : .set(nextPurpose),
            model: model == channel.model ? nil : model))
    }
}
