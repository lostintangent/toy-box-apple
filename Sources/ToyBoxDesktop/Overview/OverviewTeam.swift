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
    @FocusState private var focus: Focus?

    private var status: ChannelAgentPresence? { presence }
    private var showsMenu: Bool { isHovering || focus != nil || voiceOver }
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
            .accessibilityValue(OverviewAgentStatusLine.spoken(status, isLive: isLive))
            .accessibilityHint("Shows details about \(agent.name)")
            .accessibilityActions { actions }

            ZStack(alignment: .trailing) {
                if isLive, status?.state == "waiting", let raw = status?.wakeAt, let wake = ChannelDates.date(raw) {
                    OverviewWakeCountdown(wake: wake)
                        .opacity(showsMenu ? 0 : 1)
                }
                OverviewRowMenu(title: "Actions for \(agent.name)", isVisible: showsMenu) { actions }
                    .focused($focus, equals: .menu)
            }
            .frame(minWidth: 28, alignment: .trailing)
        }
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
        HStack(spacing: 4) {
            if presentation.cue == .working {
                OverviewWorkingEllipsis(color: agent.avatar.flatMap { Color(hex: $0.color) } ?? Color.accentColor)
                Text(presentation.text).foregroundStyle(Color.primary.opacity(0.85))
            } else {
                if presentation.cue == .waiting {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9 * textScale, weight: .heavy))
                        .foregroundStyle(ChannelAgentStatusPresentation.waitingCue(in: colorScheme))
                        .frame(width: 12 * textScale)
                        .accessibilityHidden(true)
                }
                Text(presentation.text).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11 * textScale))
        .lineLimit(1)
        .truncationMode(.tail)
        .help(presentation.text)
    }
}

/// "8 min" until a waiting agent checks again, updated at minute boundaries, then "Due".
private struct OverviewWakeCountdown: View {
    @Environment(\.channelTextScale) private var textScale
    let wake: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.remaining(until: wake, now: context.date))
                .font(.system(size: 11 * textScale).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .help("Checks again at \(wakeTime)")
        .accessibilityHidden(true)
    }

    private var wakeTime: String {
        wake.formatted(date: Calendar.current.isDateInToday(wake) ? .omitted : .abbreviated, time: .shortened)
    }

    static func remaining(until wake: Date, now: Date) -> String {
        let minutes = Int(ceil(wake.timeIntervalSince(now) / 60))
        guard minutes > 0 else { return "Due" }
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = minutes >= 60 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(minutes * 60).formatted(.units(allowed: allowed, width: .abbreviated))
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
