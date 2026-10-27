import AppKit
import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// The lead, then members alphabetically. Positions never follow presence, so the list stays scannable.
struct OverviewTeamList: View {
    @Environment(ManagementPresenter.self) private var management
    let store: ChannelStore
    @ViewState private var slots = OverviewSlots()

    /// `roster` starts with the lead.
    static func ordered(_ roster: [ChannelAgent]) -> [ChannelAgent] {
        guard let lead = roster.first else { return [] }
        return [lead] + roster.dropFirst().sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        let roster = store.roster
        let presence = store.presence
        let isLive = store.phase.isLive
        VStack(alignment: .leading, spacing: 0) {
            ForEach(slots.entries(Self.ordered(roster), in: store.id)) { entry in
                let agent = entry.item
                let isLead = agent.id == roster.first?.id
                OverviewAgentRow(agent: agent, key: entry.key, presence: presence[agent.id], isLead: isLead,
                                 model: isLead ? agent.model ?? store.details?.model : agent.model,
                                 channelId: store.id, isLive: isLive)
            }
            OverviewAddAgentRow(isLive: isLive) {
                management.present(.addMember(channelId: store.id, name: ""))
            }
        }
    }
}

struct OverviewAgentRow: View {
    private enum Focus { case row, menu }

    @Environment(ManagementPresenter.self) private var management
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let agent: ChannelAgent
    /// Names the agent for this visit to the channel. See `OverviewSlots`.
    let key: String
    let presence: ChannelAgentPresence?
    let isLead: Bool
    let model: ModelConfiguration?
    let channelId: String
    let isLive: Bool
    @ViewState private var about = OverviewItemState(false)
    @ViewState private var isHovering = false
    @ViewState private var isVisible = false
    @ViewState private var wakeAnnouncement: String?
    @FocusState private var focus: Focus?

    private var status: ChannelAgentPresence? { presence }
    private var wake: Date? { ChannelAgentWakePresentation.wake(for: presence, isLive: isLive) }
    private var showsMenu: Bool { isHovering || focus != nil || voiceOver }
    private var spokenStatus: String {
        let status = OverviewAgentStatusLine.spoken(status, isLive: isLive)
        guard wake != nil, isVisible, let wakeAnnouncement else { return status }
        return "\(status), \(wakeAnnouncement)"
    }
    private var showingAbout: Binding<Bool> {
        Binding(get: { about[key] }, set: { about[key] = $0 })
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { about[key].toggle() } label: {
                HStack(spacing: 10) {
                    AgentAvatarView(agent: agent, size: 24)
                        .popover(isPresented: showingAbout, arrowEdge: .leading) {
                            OverviewAgentAbout(agent: agent, isLead: isLead, model: model, status: status, isLive: isLive)
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.name)
                            .font(.system(size: 13 * textScale))
                            .lineLimit(1)
                        OverviewAgentStatusLine(agent: agent, status: status, isLive: isLive)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .frame(minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .row)
            .help("About \(agent.name)")
            .accessibilityLabel(agent.name)
            .accessibilityValue(spokenStatus)
            .accessibilityHint("Shows details about \(agent.name)")
            .accessibilityActions { actions }

            ZStack(alignment: .trailing) {
                if let wake {
                    ChannelAgentWakeCountdown(wake: wake, isActive: isVisible) { wakeAnnouncement = $0 }
                        .font(.system(size: 11 * textScale))
                        .opacity(showsMenu ? 0 : 1)
                        .accessibilityHidden(true)
                }
                OverviewRowMenu(title: "Actions for \(agent.name)", isVisible: showsMenu) { actions }
                    .focused($focus, equals: .menu)
            }
            .frame(minWidth: 28, alignment: .trailing)
        }
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .onDisappear { isVisible = false }
        .onHover { isHovering = $0 }
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Reply to \(agent.name)") { interaction.reply(to: agent) }
            .disabled(agent.deleted == true)
        Button("About \(agent.name)") { about[key] = true }
        if !isLead {
            Divider()
            Button("Edit Member…") {
                management.present(.editMember(channelId: channelId, agentId: agent.id))
            }
            .disabled(!isLive)
            Button("Remove Member…", role: .destructive) {
                management.present(.removeMember(channelId: channelId, agentId: agent.id))
            }
            .disabled(!isLive)
        }
    }
}

/// One 11-point line: Messages' typing cue while working, the reason while waiting, otherwise Idle.
struct OverviewAgentStatusLine: View {
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    let agent: ChannelAgent
    let status: ChannelAgentPresence?
    let isLive: Bool

    static func text(_ status: ChannelAgentPresence?, isLive: Bool) -> String {
        ChannelAgentStatusPresentation(presence: status, isLive: isLive).text
    }

    static func spoken(_ status: ChannelAgentPresence?, isLive: Bool) -> String {
        ChannelAgentStatusPresentation(presence: status, isLive: isLive).spoken
    }

    var body: some View {
        let presentation = ChannelAgentStatusPresentation(presence: status, isLive: isLive)
        HStack(alignment: presentation.cue == .waiting ? .firstTextBaseline : .center, spacing: 4) {
            if presentation.cue == .working {
                OverviewWorkingEllipsis(color: agent.avatar.flatMap { Color(hex: $0.color) } ?? Color.accentColor)
            } else {
                if presentation.cue == .waiting {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9 * textScale, weight: .heavy))
                        .foregroundStyle(ChannelAgentStatusPresentation.waitingCue(in: colorScheme))
                        .frame(width: 12 * textScale)
                        .alignmentGuide(.firstTextBaseline) {
                            $0[VerticalAlignment.center] + NSFont.systemFont(ofSize: 11 * textScale).capHeight / 2
                        }
                        .accessibilityHidden(true)
                }
            }
            Text(presentation.text).foregroundStyle(presentation.textColor)
        }
        .font(.system(size: 11 * textScale))
        .lineLimit(1)
        .truncationMode(.tail)
        .help(presentation.text)
    }
}

/// Public facts about a member: name, full role, status and model, never private session contents.
private struct OverviewAgentAbout: View {
    let agent: ChannelAgent
    let isLead: Bool
    let model: ModelConfiguration?
    let status: ChannelAgentPresence?
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentAvatarView(agent: agent, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(.headline)
                    Text(isLead ? "Lead · @\(agentHandleFromName(agent.name))" : "@\(agentHandleFromName(agent.name))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let role = agent.role, !role.isEmpty {
                ScrollView {
                    Text(role)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Status").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(OverviewAgentStatusLine.spoken(status, isLive: isLive))
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    if let model {
                        Text("\(model.name) · \(model.provider)").textSelection(.enabled)
                    } else {
                        Text("Workspace default")
                    }
                }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }
}

/// Ends the Team list: a dashed circle and secondary label that opens Add Member.
private struct OverviewAddAgentRow: View {
    @Environment(\.channelTextScale) private var textScale
    let isLive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AddAgentMark(size: 24)
                Text("Add Agent…")
                    .font(.system(size: 13 * textScale))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isLive)
        .help(isLive ? "Add a member to this channel" : "Reconnect to add a member")
    }
}

/// A dashed circle with a plus, shared by Team's Add Agent row and the Add Agent sheet.
struct AddAgentMark: View {
    let size: CGFloat

    var body: some View {
        // The sheet's 40-point mark opens its dashes and lightens its glyph to keep the row's texture.
        let isLarge = size >= 32
        ZStack {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: isLarge ? 1.25 : 1,
                                                 dash: isLarge ? [3.5, 3.5] : [2.5, 2.5]))
                .foregroundStyle(.tertiary)
            Image(systemName: "plus")
                .font(.system(size: isLarge ? 17 : 11, weight: isLarge ? .regular : .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
    }
}
