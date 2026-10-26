import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct OverviewTeamSection: View {
    let store: ChannelStore
    @Environment(ManagementPresenter.self) private var management
    @Environment(ChannelInteraction.self) private var interaction

    private var ordered: [ChannelAgent] {
        guard let lead = store.roster.first else { return [] }
        return [lead] + store.roster.dropFirst().sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        Section {
            ForEach(ordered) { agent in
                NavigationLink {
                    OverviewAgentDetails(agentID: agent.id, store: store)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        AgentAvatarView(agent: agent, size: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.name).font(.headline)
                            if let role = agent.role, !role.isEmpty {
                                Text(role).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                            OverviewAgentStatus(presence: store.presence[agent.id], live: store.phase.isLive)
                        }
                    }
                    .frame(minHeight: 64, alignment: .leading)
                }
                .contextMenu {
                    Button("Reply to \(agent.name)") {
                        interaction.isInspectorPresented = false
                        interaction.reply(to: agent)
                    }
                    NavigationLink("About \(agent.name)") { OverviewAgentDetails(agentID: agent.id, store: store) }
                    if agent.id != store.roster.first?.id {
                        Button("Edit Agent", systemImage: "pencil") {
                            management.present(.editMember(channelId: store.id, agentId: agent.id))
                        }
                        .disabled(!store.phase.isLive)
                        Button("Remove from Channel", systemImage: "person.badge.minus", role: .destructive) {
                            management.present(.removeMember(channelId: store.id, agentId: agent.id))
                        }
                        .disabled(!store.phase.isLive)
                    }
                }
            }
            Button("Add Agent", systemImage: "person.badge.plus") {
                management.present(.addMember(channelId: store.id, name: ""))
            }
            .frame(minHeight: 44)
            .disabled(!store.phase.isLive)
        } header: {
            Text("Team · \(store.roster.count)")
        }
    }
}

private struct OverviewAgentDetails: View {
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
                        Text("@\(agentHandleFromName(agent.name))").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Text(agent.role.flatMap { $0.isEmpty ? nil : $0 } ?? "No role provided")
                    .textSelection(.enabled)
            }
            Section("Status") {
                OverviewAgentStatus(presence: store.presence[agentID], live: store.phase.isLive)
                if store.phase.isLive, let presence = store.presence[agentID], presence.state == "waiting",
                   let wake = presence.wakeAt.flatMap(ChannelDates.date) {
                    LabeledContent("Checks again", value: wake.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("Model") {
                if let model {
                    LabeledContent("Provider", value: model.provider)
                    LabeledContent("Model", value: model.name)
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
                    Text("Workspace default. No member override is set.").foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
        .navigationTitle("About Agent")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OverviewAgentStatus: View {
    let presence: ChannelAgentPresence?
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !live || presence == nil {
                Text("Status unavailable").foregroundStyle(.secondary)
            } else if let presence {
                Text(presence.state == "working" ? "Working" : presence.state == "waiting" ? "Waiting" : "Idle")
                    .foregroundStyle(.secondary)
                if let text = presence.text, !text.isEmpty { Text(text) }
                if presence.state == "waiting", let wake = presence.wakeAt.flatMap(ChannelDates.date) {
                    TimelineView(.everyMinute) { context in
                        let minutes = max(0, Int(ceil(wake.timeIntervalSince(context.date) / 60)))
                        Text(minutes == 0 ? "Check-in due" : "Checks again in \(minutes) min")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
    }
}
