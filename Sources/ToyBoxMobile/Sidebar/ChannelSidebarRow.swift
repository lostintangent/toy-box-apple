import ChannelKit
import SwiftUI
import ToyBoxUI

struct ChannelSidebarRow: View {
    let channel: Channel
    let agents: [ChannelAgent]
    let working: [ChannelAgent]
    let attention: ChannelAttention?
    let now: Date
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            ChannelMark(size: 28, emphasized: prominence == .increased)
            VStack(alignment: .leading, spacing: 4) {
                heading
                if let path = channel.directory, !path.isEmpty {
                    Label((path as NSString).lastPathComponent, systemImage: "folder")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.middle)
                } else if let purpose = channelPurposePreview(channel.purpose) {
                    Text(purpose)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                if dynamicTypeSize.isAccessibilitySize {
                    AgentAvatarStack(agents: agents, size: 20, limit: 4)
                    status
                } else {
                    ViewThatFits(in: .horizontal) {
                        teamAndStatus(faceLimit: 4)
                        teamAndStatus(faceLimit: 1)
                        VStack(alignment: .leading, spacing: 4) {
                            AgentAvatarStack(agents: agents, size: 20, limit: 1)
                            status
                        }
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 96)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channel.name)
        .accessibilityValue(accessibilityDetails)
    }

    @ViewBuilder private var heading: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                title
                activity
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title.lineLimit(1).truncationMode(.tail)
                activity
            }
        }
    }

    private var title: some View {
        Text(channel.name)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var activity: some View {
        if let date = ChannelDates.date(channel.updatedAt) {
            Text(ChannelActivityTime.label(for: date, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private func teamAndStatus(faceLimit: Int) -> some View {
        HStack(spacing: 8) {
            AgentAvatarStack(agents: agents, size: 20, limit: faceLimit)
                .fixedSize()
            inlineStatus.fixedSize()
            Spacer(minLength: 0)
        }
    }

    private var status: some View {
        ViewThatFits(in: .horizontal) {
            inlineStatus.fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                attentionLabel
                workingLabel
            }
        }
        .font(.footnote)
    }

    private var inlineStatus: some View {
        HStack(spacing: 8) {
            attentionLabel
            workingLabel
        }
        .font(.footnote)
    }

    private var attentionColor: Color {
        guard let attention else { return .primary }
        return prominence == .increased ? .white : ChannelAttentionStyle.color(for: attention, in: colorScheme)
    }

    @ViewBuilder private var attentionLabel: some View {
        if let attention {
            HStack(spacing: 4) {
                if attention == .unread {
                    Circle().fill(attentionColor)
                        .frame(width: 7, height: 7)
                } else {
                    Image(systemName: ChannelAttentionStyle.symbol(for: attention))
                        .font(.footnote.weight(.semibold))
                }
                Text(attentionText)
            }
            .foregroundStyle(attentionColor)
        }
    }

    @ViewBuilder private var workingLabel: some View {
        if !working.isEmpty {
            Text("Working").foregroundStyle(.secondary)
        }
    }

    private var attentionText: String {
        switch attention {
        case .waiting: "Needs you"
        case .finished: "Finished"
        case .unread: "Unread"
        case nil: ""
        }
    }

    private var accessibilityDetails: String {
        var parts = [channel.directory ?? channel.purpose ?? ""]
        if !attentionText.isEmpty { parts.append(attentionText) }
        if !working.isEmpty { parts.append(working.map(\.name).formatted(.list(type: .and)) + " working") }
        parts.append("Team: " + agents.map(\.name).formatted(.list(type: .and)))
        if let date = ChannelDates.date(channel.updatedAt) {
            parts.append(ChannelActivityTime.accessibilityLabel(for: date, now: now))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}
