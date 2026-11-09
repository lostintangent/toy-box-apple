import Foundation

/// A channel's descriptive fields, without the counters and timestamps that every message moves.
public struct ChannelDetails: Equatable, Sendable {
    public var id: String
    public var name: String
    public var purpose: String?
    public var directory: String?
    public var model: ModelConfiguration
    public var preview: ChannelPreview?

    public init(_ channel: Channel) {
        id = channel.id
        name = channel.name
        purpose = channel.purpose
        directory = channel.directory
        model = channel.model
        preview = channel.preview
    }

    public func applying(to channel: Channel, requestSequence: Int?) -> Channel {
        var live = channel
        live.name = name
        live.purpose = purpose
        live.directory = directory
        live.model = model
        live.preview = preview
        live.requestSequence = requestSequence
        return live
    }
}
