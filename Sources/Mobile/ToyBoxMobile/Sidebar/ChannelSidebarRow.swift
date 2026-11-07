import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ChannelSidebarRow: View {
    let channel: Channel
    let agents: [ChannelAgent]
    let working: [ChannelAgent]
    let attention: Channel.Attention?
    let now: Date
    /// Only a collapsed split view draws the chevron. The scene decides, because UIKit gives the
    /// expanded sidebar column a compact width of its own.
    var isCollapsed = false
    /// The swipe-to-talk recorder, only while it's on this row.
    var talk: TalkRecorder? = nil
    /// A waiting request's question, which takes the folder's or purpose's place in one line.
    var question: String? = nil
    /// The done check, once this row's reply sends from its Needs You card.
    var check: CardChecks.Check? = nil
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            ChannelMark(size: 28, emphasized: prominence == .increased)
                .needsYouMark(check, emphasized: prominence == .increased)
                .talkMark(talk, emphasized: prominence == .increased)
            VStack(alignment: .leading, spacing: 8) {
                heading
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            detail(yields: true)
                            if !working.isEmpty {
                                AgentAvatarStack(agents: working, size: 20, limit: 3)
                            }
                            attentionLabel.talkFades(talk)
                        }
                    } else {
                        secondLine
                    }
                }
                .talkLine(talk)
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channel.name)
        .talkValue(talk, details: accessibilityDetails)
    }

    @ViewBuilder private var heading: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                title
                Activity(channel: channel, now: now, isCollapsed: isCollapsed, talk: talk)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title.lineLimit(1).truncationMode(.tail)
                Activity(channel: channel, now: now, isCollapsed: isCollapsed, talk: talk)
            }
        }
    }

    private var title: some View {
        Text(channel.name)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            attentionLabel.talkFades(talk).fixedSize()
        }
    }

    @ViewBuilder private func detail(yields: Bool) -> some View {
        if let question {
            Text(question)
                .font(.subheadline)
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .frame(minWidth: 0, idealWidth: yields ? nil : 60, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        } else if let path = channel.directory, !path.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "folder")
                Text(ChannelFolderName.name(of: path))
            }
                .font(.footnote)
                .foregroundStyle(ChannelInk.secondary(for: prominence))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: !yields, vertical: false)
                .layoutPriority(1)
        } else if let purpose = channel.purposePreview {
            Text(purpose)
                .font(.footnote)
                .foregroundStyle(ChannelInk.secondary(for: prominence))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .frame(minWidth: 0, idealWidth: yields ? nil : 60, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
    }

    private var attentionColor: Color {
        guard let attention else { return .primary }
        return prominence == .increased ? .white : attention.color(in: colorScheme)
    }

    @ViewBuilder private var attentionLabel: some View {
        if let attention {
            if attention == .unread {
                Circle().fill(attentionColor)
                    .frame(width: 7, height: 7)
            } else {
                Image(systemName: attention.symbol)
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
        var parts = [question ?? channel.directory ?? channel.purpose ?? ""]
        if !attentionText.isEmpty { parts.append(attentionText) }
        if !working.isEmpty { parts.append(working.map(\.name).formatted(.list(type: .and)) + " working") }
        parts.append("Team: " + agents.map(\.name).formatted(.list(type: .and)))
        if let date = try? Date(channel.updatedAt, strategy: .iso8601) {
            parts.append(ChannelActivityTime.accessibilityLabel(for: date, now: now))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

extension ChannelSidebarRow {
    /// The row's last activity time, then the chevron when the split view is collapsed. The talk
    /// card's time takes the time's place, and a Needs You card's heading ends in the same column.
    struct Activity: View {
        let channel: Channel
        let now: Date
        var isCollapsed = false
        var talk: TalkRecorder? = nil
        @Environment(\.backgroundProminence) private var prominence

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ZStack {
                    if let date = try? Date(channel.updatedAt, strategy: .iso8601) {
                        Text(ChannelActivityTime.label(for: date, now: now))
                            .font(.caption)
                            .foregroundStyle(ChannelInk.secondary(for: prominence))
                    }
                }
                .talkTime(talk)
                if isCollapsed {
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(uiColor: prominence == .increased ? .white : .tertiaryLabel))
                        .talkFades(talk)
                        .accessibilityHidden(true)
                }
            }
            .fixedSize()
        }
    }
}
