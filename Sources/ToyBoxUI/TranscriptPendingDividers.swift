import ChannelKit

/// The day divider each pending message's row will have once it's sent, keyed by message ID, so the
/// divider is already there and doesn't appear on confirming. `last` is the newest loaded message.
public func transcriptPendingDividers(_ pending: [ChannelMessage], after last: ChannelMessage?,
                                      roster: [ChannelAgent]) -> [String: TranscriptDivider] {
    guard let lead = roster.first else { return [:] }
    let members = Array(roster.dropFirst())
    var previous = last
    var dividers: [String: TranscriptDivider] = [:]
    for message in pending {
        dividers[message.id] = transcriptRows([previous, message].compactMap(\.self), lead: lead, members: members)
            .last?.divider
        previous = message
    }
    return dividers
}
