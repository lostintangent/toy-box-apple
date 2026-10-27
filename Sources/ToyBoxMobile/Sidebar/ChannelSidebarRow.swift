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
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack(spacing: 12) {
            ChannelMark(size: 28, emphasized: prominence == .increased)
            VStack(alignment: .leading, spacing: 8) {
                heading
                if dynamicTypeSize.isAccessibilitySize {
                    detail(yields: true)
                    if !working.isEmpty {
                        AgentAvatarStack(agents: working, size: 20, limit: 3)
                    }
                    attentionLabel
                } else {
                    secondLine
                }
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 72)
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

    private var activity: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let date = ChannelDates.date(channel.updatedAt) {
                Text(ChannelActivityTime.label(for: date, now: now))
                    .font(.caption)
                    .foregroundStyle(ChannelInk.secondary)
            }
            if sizeClass == .compact {
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(uiColor: prominence == .increased ? .white : .tertiaryLabel))
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
    }

    private var secondLine: some View {
        let limits = AgentAvatarStack.faceLimits(for: working.count)
        return ViewThatFits(in: .horizontal) {
            ForEach(limits, id: \.self) { limit in
                secondLine(faceLimit: limit, detailYields: false)
            }
            secondLine(faceLimit: limits.last ?? 0, detailYields: true)
        }
    }

    private func secondLine(faceLimit: Int, detailYields: Bool) -> some View {
        HStack(spacing: 8) {
            detail(yields: detailYields)
            Spacer(minLength: 0)
            if faceLimit > 0 {
                AgentAvatarStack(agents: working, size: 20, limit: faceLimit)
                    .fixedSize()
            }
            attentionLabel.fixedSize()
        }
    }

    @ViewBuilder private func detail(yields: Bool) -> some View {
        if let path = channel.directory, !path.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "folder")
                Text(ChannelFolderName.name(of: path))
            }
                .font(.footnote)
                .foregroundStyle(ChannelInk.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: !yields, vertical: false)
                .layoutPriority(1)
        } else if let purpose = channelPurposePreview(channel.purpose) {
            Text(purpose)
                .font(.footnote)
                .foregroundStyle(ChannelInk.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .frame(minWidth: 0, idealWidth: yields ? nil : 60, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
    }

    private var attentionColor: Color {
        guard let attention else { return .primary }
        return prominence == .increased ? .white : ChannelAttentionStyle.color(for: attention, in: colorScheme)
    }

    @ViewBuilder private var attentionLabel: some View {
        if let attention {
            if attention == .unread {
                Circle().fill(attentionColor)
                    .frame(width: 7, height: 7)
            } else {
                Image(systemName: ChannelAttentionStyle.symbol(for: attention))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(attentionColor)
            }
        }
    }

    private var attentionText: String {
        switch attention {
        case .waiting: "Waiting for your response"
        case .finished: "All tasks completed"
        case .unread: "Unread messages"
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
