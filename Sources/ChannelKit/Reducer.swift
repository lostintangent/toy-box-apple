import Foundation

public func reduceChannelState(_ previous: ChannelState,
                               _ event: ChannelObservationEvent) -> ChannelState {
    if event.type == "snapshot", let snapshot = event.state { return snapshot }
    var next = previous
    if event.type == "message", event.revision == nil, var message = event.message {
        guard !previous.messages.contains(where: { $0.id == message.id }) else { return previous }
        message.sequence = (previous.messages.last?.sequence ?? 0) + 1
        next.messages = upsertMessage(previous.messages, message)
        return next
    }
    if event.type == "presence" || event.type == "resumed" {
        let incoming = event.presence ?? [:]
        next.presence = event.type == "resumed"
            ? incoming : previous.presence.merging(incoming) { _, new in new }
        return next
    }
    guard let revision = event.revision, revision > previous.revision else { return previous }
    next.revision = revision
    switch event.type {
    case "tasks":
        if let tasks = event.tasks { next.channel.tasks = tasks }
    case "model":
        if let model = event.model { next.channel.model = model }
        if let date = event.updatedAt { next.channel.updatedAt = date }
    case "read":
        if let sequence = event.seenThrough { next.channel.seenThrough = sequence }
    case "status":
        if event.agentId == next.lead.id { next.lead.status = event.status }
        else if let index = next.members.firstIndex(where: { $0.id == event.agentId }) {
            next.members[index].status = event.status
        }
    case "member":
        if let member = event.member { upsertMember(&next, member) }
    case "reaction":
        next.messages = next.messages.map { reduceReaction($0, event) }
        if let request = next.request { next.request = reduceReaction(request, event) }
    case "message":
        if let message = event.message {
            next.messages = upsertMessage(previous.messages, message)
            next.channel.latestSequence = max(previous.channel.latestSequence, message.sequence)
            next.channel.updatedAt = message.timestamp
            if !message.isSystem {
                if message.sender.type == "user" { next.channel.requestSequence = nil }
                else if message.request == true { next.channel.requestSequence = message.sequence }
            } else if let content = message.system {
                switch content.type {
                case "channel_renamed":
                    if let name = content.name { next.channel.name = name }
                case "channel_purpose_changed":
                    next.channel.purpose = content.purpose
                case "channel_directory_changed":
                    next.channel.directory = content.directory
                case "preview_changed":
                    next.channel.preview = content.preview
                    next.channel.previewUrl = content.previewUrl
                case "tasks_completed":
                    next.channel.completedSequence = message.sequence
                case "member_joined":
                    if let member = content.member { upsertMember(&next, member) }
                case "member_left":
                    if let member = content.member {
                        next.members.removeAll { $0.id == member.id }
                        next.presence.removeValue(forKey: member.id)
                        next.channel.tasks = unassignChannelTasks(next.channel.tasks, agentId: member.id)
                    }
                case "artifact_shared":
                    if var artifact = content.artifact {
                        artifact.id = artifact.file.id
                        if let index = next.artifacts.firstIndex(where: { $0.id == artifact.id }) {
                            artifact.sharedAt = next.artifacts[index].sharedAt
                            artifact.url = artifact.url ?? next.artifacts[index].url
                            next.artifacts[index] = artifact
                        } else {
                            artifact.sharedAt = message.timestamp
                            next.artifacts.append(artifact)
                        }
                    }
                case "routine_scheduled", "routine_edited":
                    if let routine = content.routine {
                        if let index = next.routines.firstIndex(where: { $0.id == routine.id }) {
                            next.routines[index] = routine
                        } else { next.routines.append(routine) }
                    }
                case "routine_deleted":
                    if let routine = content.routine { next.routines.removeAll { $0.id == routine.id } }
                default: break
                }
            }
        }
    default: break
    }
    if next.channel.requestSequence != previous.channel.requestSequence {
        next.request = event.message.flatMap { !$0.isSystem && $0.request == true ? $0 : nil }
    }
    return next
}

public func mergeChannelMessages(_ messages: [ChannelMessage],
                                 incoming: [ChannelMessage]) -> [ChannelMessage] {
    var ids = Set(messages.map(\.id))
    let additions = incoming.filter { ids.insert($0.id).inserted }
    return additions.isEmpty ? messages : (messages + additions).sorted { $0.sequence < $1.sequence }
}

private func upsertMessage(_ messages: [ChannelMessage], _ message: ChannelMessage) -> [ChannelMessage] {
    var next = messages.filter { $0.id != message.id }
    let index = next.firstIndex { $0.sequence >= message.sequence } ?? next.endIndex
    next.insert(message, at: index)
    return next
}

private func upsertMember(_ state: inout ChannelState, _ member: ChannelMember) {
    state.members.removeAll { $0.id == member.id }
    state.members.append(member)
    state.members.sort {
        let comparison = $0.name.localizedCompare($1.name)
        return comparison == .orderedSame ? $0.id.localizedCompare($1.id) == .orderedAscending
            : comparison == .orderedAscending
    }
}

private func reduceReaction(_ message: ChannelMessage,
                            _ event: ChannelObservationEvent) -> ChannelMessage {
    guard message.sequence == event.sequence, !message.isSystem, let agentId = event.agentId else {
        return message
    }
    var next = message
    var reactions = (message.reactions ?? []).filter { $0.agentId != agentId }
    if let reaction = event.reaction { reactions.append(.init(agentId: agentId, reaction: reaction)) }
    next.reactions = reactions.isEmpty ? nil : reactions
    return next
}
