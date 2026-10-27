import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

struct OverviewTeamSection: View {
    let store: ChannelStore
    let session: OverviewSession
    @Environment(ManagementPresenter.self) private var management
    @Environment(\.dynamicTypeSize) private var typeSize

    private var ordered: [ChannelAgent] {
        guard let lead = store.roster.first else { return [] }
        return [lead] + store.roster.dropFirst().sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        let verticalInset: CGFloat = typeSize.isAccessibilitySize ? 15 : 14
        OverviewSectionRows(summary: .team(store.roster.count), section: .team, session: session,
                            isFirstSection: false) {
            ForEach(ordered) { agent in
                OverviewTeamRow(agent: agent, store: store, session: session,
                                isLead: agent.id == store.roster.first?.id)
                    .listRowInsets(.vertical, typeSize.isAccessibilitySize ? nil : 14)
            }
            Button {
                management.present(.addMember(channelId: store.id, name: ""))
            } label: {
                Label("Add Agent", systemImage: "person.badge.plus")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .padding(.vertical, verticalInset)
                    .contentShape(Rectangle())
            }
            .listRowInsets(.vertical, 0)
            .accessibilityIdentifier("overview-add-agent")
            .disabled(!store.phase.isLive)
            .modifier(OverviewListRowBoundary(isLast: true))
        }
    }
}

struct OverviewTeamRow: View {
    let agent: ChannelAgent
    let store: ChannelStore
    let session: OverviewSession
    let isLead: Bool
    @Environment(ManagementPresenter.self) private var management
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ChannelArtifactSession.self) private var viewer
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @ScaledMetric(relativeTo: .body) private var avatarSize = 28
    @ViewState private var isVisible = false
    @ViewState private var wakeAnnouncement: String?

    private var wake: Date? {
        ChannelAgentWakePresentation.wake(for: store.presence[agent.id], isLive: store.phase.isLive)
    }
    private var status: ChannelAgentStatusPresentation {
        .init(presence: store.presence[agent.id], isLive: store.phase.isLive)
    }
    private var canManage: Bool { store.phase.isLive && agent.deleted != true }
    private var active: Bool {
        isVisible && interaction.isInspectorPresented && management.flow == nil
            && !viewer.isPresented && session.navigationPath.isEmpty
    }

    var body: some View {
        NavigationLink(value: OverviewRoute.agent(agent.id)) {
            HStack(spacing: 12) {
                AgentAvatarView(agent: agent, size: min(36, avatarSize))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(.body)
                    OverviewAgentStatus(presence: store.presence[agent.id], live: store.phase.isLive, active: active)
                }
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let wake {
                    ChannelAgentWakeCountdown(wake: wake, isActive: active) { wakeAnnouncement = $0 }
                        .font(.footnote)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 38, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.name), \(status.spoken)")
        .accessibilityValue(wake != nil && active ? wakeAnnouncement ?? "" : "")
        .accessibilityHint("Shows agent details")
        .accessibilityIdentifier("overview-agent-\(agent.id)")
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .onDisappear { isVisible = false }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isLead, !voiceOver {
                Button("Remove", systemImage: "person.badge.minus", role: .destructive, action: remove)
                    .disabled(!canManage)
                Button("Edit", systemImage: "pencil", action: edit)
                    .disabled(!canManage)
            }
        }
        .contextMenu {
            Button("Reply to \(agent.name)") { reply() }
                .disabled(agent.deleted == true)
            NavigationLink("About \(agent.name)", value: OverviewRoute.agent(agent.id))
            if !isLead {
                Button("Edit Agent", systemImage: "pencil", action: edit).disabled(!canManage)
                Button("Remove from Channel", systemImage: "person.badge.minus", role: .destructive, action: remove)
                    .disabled(!canManage)
            }
        }
        .accessibilityActions {
            Button("Reply to \(agent.name)", action: reply).disabled(agent.deleted == true)
            if !isLead {
                Button("Edit \(agent.name)", action: edit).disabled(!canManage)
                Button("Remove \(agent.name) from channel", action: remove).disabled(!canManage)
            }
        }
    }

    private func edit() { management.present(.editMember(channelId: store.id, agentId: agent.id)) }
    private func remove() { management.present(.removeMember(channelId: store.id, agentId: agent.id)) }
    private func reply() {
        interaction.isInspectorPresented = false
        interaction.reply(to: agent)
    }
}

struct OverviewAgentDetails: View {
    let agentID: String
    let store: ChannelStore
    private var agent: ChannelAgent { channelAgentIdentity(store.roster, id: agentID) }
    private var model: ModelConfiguration? {
        agentID == store.roster.first?.id ? agent.model ?? store.details?.model : agent.model
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AgentAvatarView(agent: agent, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.name).font(.headline)
                        Text("@\(agentHandleFromName(agent.name))").font(.footnote).foregroundStyle(ChannelInk.secondary)
                    }
                }
            }
            Section {
                OverviewAgentStatus(presence: store.presence[agentID], live: store.phase.isLive)
                if let wake = ChannelAgentWakePresentation.wake(for: store.presence[agentID],
                                                                isLive: store.phase.isLive) {
                    LabeledContent("Checks again") {
                        Text(wake.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(ChannelInk.secondary)
                    }
                }
            } header: {
                Text("Status").foregroundStyle(ChannelInk.secondary)
            }
            Section {
                if let model {
                    LabeledContent("Provider") {
                        Text(model.provider).foregroundStyle(ChannelInk.secondary)
                    }
                    LabeledContent("Model") {
                        Text(model.name).foregroundStyle(ChannelInk.secondary)
                    }
                    if !model.options.isEmpty {
                        switch Result(catching: { try JSONEncoder().encode(model.options) }) {
                        case .success(let data):
                            Text(String(decoding: data, as: UTF8.self))
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        case .failure(let error):
                            ManagementError(message: "Model options could not be displayed. \(error.localizedDescription)")
                        }
                    }
                } else {
                    Text("Workspace default. No member override is set.").foregroundStyle(ChannelInk.secondary)
                }
            } header: {
                Text("Model").foregroundStyle(ChannelInk.secondary)
            }
        }
        .textSelection(.enabled)
        .navigationTitle("About Agent")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct OverviewAgentStatus: View {
    let presence: ChannelAgentPresence?
    let live: Bool
    var active = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var cueSize = 9
    @ScaledMetric(relativeTo: .footnote) private var cueWidth = 12

    var body: some View {
        let status = ChannelAgentStatusPresentation(presence: presence, isLive: live)
        // Scaled metrics do not track the preferred font's point size at accessibility sizes.
        let capHeight = UIFont.preferredFont(
            forTextStyle: .footnote,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))).capHeight
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if status.cue == .working {
                OverviewWorkingEllipsis(size: cueSize, active: active)
                    .frame(width: cueWidth, height: cueSize)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    .accessibilityHidden(true)
            } else if status.cue == .waiting {
                Image(systemName: "pause.fill")
                    .font(.system(size: cueSize, weight: .heavy))
                    .foregroundStyle(ChannelAgentStatusPresentation.waitingCue(in: colorScheme))
                    .frame(width: cueWidth)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + capHeight / 2 }
                    .accessibilityHidden(true)
            }
            Text(status.text).foregroundStyle(status.textColor)
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.spoken)
    }
}
