import Foundation

public enum ChannelAttention: String, Sendable {
    case waiting, finished, unread
}

public func channelStatus(_ channel: Channel) -> ChannelAttention? {
    if channel.requestSequence != nil { return .waiting }
    if (channel.completedSequence ?? 0) > channel.seenThrough { return .finished }
    return channel.latestSequence > channel.seenThrough ? .unread : nil
}

public func channelSidebarStatus(_ channel: Channel, isOpen: Bool) -> ChannelAttention? {
    let status = channelStatus(channel)
    return status == .waiting || !isOpen ? status : nil
}

public func channelUnreadAfter(_ channel: Channel) -> Int? {
    channel.latestSequence > channel.seenThrough ? channel.seenThrough : nil
}
