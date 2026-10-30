import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

struct OverviewTeamSection: View {
    let store: ChannelStore
    let session: OverviewSession
    let placement: OverviewPlacement
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
        // Four points shorter than the measured 15-point native insets at accessibility sizes,
        // and six shorter at ordinary sizes.
        let verticalInset: CGFloat = typeSize.isAccessibilitySize ? 13 : 12
        OverviewSectionRows(summary: .team(store.roster.count), section: .team, session: session,
                            isFirstSection: !OverviewAboutSection.hasContent(store.details)) {
            ForEach(ordered) { agent in
                OverviewTeamRow(agent: agent, store: store, session: session,
                                isLead: agent.id == store.roster.first?.id, placement: placement)
                    .listRowInsets(.vertical, verticalInset)
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
            .disabled(!store.phase.isConnected)
            .modifier(OverviewListRowBoundary(isLast: true))
        }
    }
}

struct OverviewTeamRow: View {
    let agent: ChannelAgent
    let store: ChannelStore
    let session: OverviewSession
    let isLead: Bool
    let placement: OverviewPlacement
    @Environment(ManagementPresenter.self) private var management
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ChannelArtifactSession.self) private var viewer
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.overviewWindowSizeClass) private var windowSizeClass
    @ScaledMetric(relativeTo: .body) private var avatarSize = 28
    @ViewState private var isVisible = false
    @ViewState private var wakeAnnouncement: String?
    @Environment(\.overviewHeight) private var overviewHeight
    @ViewState private var showsAbout = false

    private var wake: Date? {
        ChannelAgentWakePresentation.wake(for: store.presence[agent.id], isAvailable: !store.phase.isUnavailable)
    }
    private var status: ChannelAgentStatusPresentation {
        .init(presence: store.presence[agent.id], isAvailable: !store.phase.isUnavailable)
    }
    private var canManage: Bool { store.phase.isConnected && agent.deleted != true }
    private var active: Bool {
        isVisible && interaction.isInspectorPresented && management.flow == nil
            && !viewer.isPresented && session.navigationPath.isEmpty
    }

    var body: some View {
        Button { showsAbout.toggle() } label: {
            HStack(spacing: 12) {
                AgentAvatarView(agent: agent, size: min(36, avatarSize))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    // A list button tints its label, so the name keeps the primary ink.
                    Text(agent.name).font(.body).foregroundStyle(.primary)
                    OverviewAgentStatus(presence: store.presence[agent.id], available: !store.phase.isUnavailable,
                                        active: active)
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
        // In a regular-width window it's the Mac's popover, even from the Overview sheet. In the column
        // it opens toward the conversation: iOS puts the arrow on this edge of the popover, so trailing
        // points it back at the row. Elsewhere the system picks above or below the row. A compact
        // window adapts it to a sheet sized to its content, whose medium detent is about half of the
        // Overview it rises over.
        .popover(isPresented: $showsAbout, attachmentAnchor: .rect(.bounds),
                 arrowEdge: placement == .inspector ? .trailing : nil) {
            OverviewAgentAbout(agentID: agent.id, store: store,
                               style: windowSizeClass == .regular ? .popover : .sheet(mediumHeight: overviewHeight / 2))
        }
        // The button is already one element, and keeps its activation.
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
            Button("About \(agent.name)") { showsAbout = true }
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

/// The Mac's About popover on the phone: name, handle, full role, status and model. It reads the
/// store, so status, wake and model update while it's open. It never shows private session contents.
/// A compact window adapts it to a sheet sized to its content, as Apple's guidelines ask.
struct OverviewAgentAbout: View {
    enum Style: Equatable {
        case popover
        /// Fits its content up to the medium detent, which is half the height the sheet can take.
        case sheet(mediumHeight: CGFloat)
    }

    let agentID: String
    let store: ChannelStore
    let style: Style
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var roleHeight = 210
    @ViewState private var fittedHeight: CGFloat = 0

    private var agent: ChannelAgent { channelAgentIdentity(store.roster, id: agentID) }
    private var isLead: Bool { agentID == store.roster.first?.id }
    private var model: ModelConfiguration? { isLead ? agent.model ?? store.details?.model : agent.model }
    private var handle: String { "@\(agentHandleFromName(agent.name))" }
    private var facts: [Fact] {
        let available = !store.phase.isUnavailable
        var facts = [Fact(key: "Status", lines: [
            ChannelAgentStatusPresentation(presence: store.presence[agentID], isAvailable: available).spoken
        ])]
        if let wake = ChannelAgentWakePresentation.wake(for: store.presence[agentID], isAvailable: available) {
            facts.append(Fact(key: "Checks again", lines: [
                wake.formatted(date: Calendar.current.isDateInToday(wake) ? .omitted : .abbreviated, time: .shortened)
            ]))
        }
        if let model {
            facts.append(Fact(key: "Model", lines: ["\(model.name) · \(model.provider)"]
                + (model.reasoningLabel.map { ["\($0) reasoning"] } ?? []), selectable: true))
        } else {
            facts.append(Fact(key: "Model", lines: ["Workspace default"]))
        }
        return facts
    }

    var body: some View {
        Group {
            switch style {
            case .popover:
                // Accessibility sizes and short scenes such as folded landscape scroll the popover as one.
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView { content }
                }
                .accessibilityIdentifier("overview-agent-about")
            case .sheet(let mediumHeight):
                NavigationStack {
                    ScrollView { content }
                        .accessibilityIdentifier("overview-agent-about")
                        .scrollIndicatorsFlash(onAppear: true)
                        .onScrollGeometryChange(for: CGFloat.self) {
                            $0.contentSize.height + $0.contentInsets.top
                        } action: { _, height in
                            fittedHeight = height
                        }
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(role: .close) { dismiss() }
                                    .accessibilityLabel("Close About \(agent.name)")
                            }
                        }
                }
                .presentationDetents(fittedHeight > 0 && fittedHeight <= mediumHeight
                                     ? [.height(fittedHeight)] : [.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .presentationCompactAdaptation(.sheet)
    }

    /// The popover bounds a long role and keeps UIKit's popover width. The sheet and accessibility
    /// sizes let it run, and the whole content scrolls as one.
    private var isBoundedPopover: Bool { style == .popover && !typeSize.isAccessibilitySize }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let role = agent.role, !role.isEmpty {
                let text = Text(role).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !isBoundedPopover {
                    text.fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView { text }
                        .frame(maxHeight: roleHeight)
                        .fixedSize(horizontal: false, vertical: true)
                        .scrollIndicatorsFlash(onAppear: true)
                }
            }
            factsView.font(.subheadline)
        }
        .padding(20)
        .frame(width: isBoundedPopover ? 320 : nil, alignment: .leading)
        .frame(maxWidth: isBoundedPopover ? nil : .infinity, alignment: .leading)
    }

    private var header: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            AgentAvatarView(agent: agent, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.headline)
                Text(isLead ? "Lead · \(handle)" : handle)
                    .font(.subheadline)
                    .foregroundStyle(ChannelInk.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLead ? "\(agent.name), Lead, \(handle)" : "\(agent.name), \(handle)")
    }

    @ViewBuilder private var factsView: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.key).foregroundStyle(ChannelInk.secondary)
                        value(fact)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(fact.spoken)
                }
            }
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(facts) { fact in
                    GridRow {
                        Text(fact.key)
                            .foregroundStyle(ChannelInk.secondary)
                            .gridColumnAlignment(.trailing)
                            .accessibilityHidden(true)
                        // Without a flexible value, Grid splits the width evenly and wraps values early.
                        value(fact)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(fact.spoken)
                    }
                }
            }
        }
    }

    private func value(_ fact: Fact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(fact.lines.enumerated()), id: \.offset) { index, line in
                if index == 0, fact.selectable {
                    Text(line).textSelection(.enabled)
                } else {
                    Text(line).foregroundStyle(index == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(ChannelInk.secondary))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    struct Fact: Identifiable {
        let key: String
        let lines: [String]
        var selectable = false
        var id: String { key }
        var spoken: String { ([key] + lines).joined(separator: ", ") }
    }
}

struct OverviewAgentStatus: View {
    let presence: ChannelAgentPresence?
    let available: Bool
    var active = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var cueSize = 9
    @ScaledMetric(relativeTo: .footnote) private var cueWidth = 12

    var body: some View {
        let status = ChannelAgentStatusPresentation(presence: presence, isAvailable: available)
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
