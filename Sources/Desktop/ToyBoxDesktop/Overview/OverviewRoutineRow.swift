import ChannelClient
import ChannelKit
import Foundation
import SwiftUI
import ToyBoxUI

/// A routine shares the artifact geometry, with its prompt disclosed in place.
struct OverviewRoutineRow: View {
    private enum Focus { case row, menu }

    @Environment(ManagementPresenter.self) private var management
    @Environment(\.windowSnapshot) private var snapshot
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let routine: ChannelRoutine
    /// Names the routine for this visit to the channel. See `OverviewSlots`.
    let key: String
    let store: ChannelStore
    let onExpand: () -> Void
    @ViewState private var item = OverviewItemState(Item())
    @ViewState private var isHovering = false
    @FocusState private var focus: Focus?

    private struct Item {
        var expanded = false
        var isRunning = false
        var runRequestedAt: Date?
        var error: String?
    }

    private var expanded: Bool { item[key].expanded }
    private var isRunning: Bool { item[key].isRunning }
    private var runRequestedAt: Date? { item[key].runRequestedAt }
    private var canRun: Bool { !isRunning && store.phase.isConnected }
    private var showsMenu: Bool { isHovering || focus != nil || voiceOver }
    private var scheduleSummary: String { RoutineScheduleSummary.text(for: routine.schedule) }
    private var scheduleLine: String {
        ChannelRoutineRunPresentation.label(schedule: scheduleSummary, pending: isRunning, requestedAt: runRequestedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { setExpanded(!expanded) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 15 * textScale))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            OverviewInlineDisclosure.line(
                                Text(verbatim: routine.title.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.system(size: 13 * textScale)),
                                isExpanded: expanded, textScale: textScale)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(scheduleLine)
                                .font(.system(size: 11 * textScale))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(scheduleSummary == routine.schedule
                                      ? routine.schedule : "\(scheduleSummary)\n\(routine.schedule)")
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focus, equals: .row)
                .onKeyPress(.rightArrow) { setExpanded(true); return .handled }
                .onKeyPress(.leftArrow) { setExpanded(false); return .handled }
                .accessibilityLabel(routine.title)
                .accessibilityValue("\(scheduleLine), \(expanded ? "Expanded" : "Collapsed")")
                .accessibilityHint(expanded ? "Hides the prompt" : "Shows the prompt")
                .accessibilityActions { actions }
                OverviewRowMenu(title: "Actions for \(routine.title)", isVisible: showsMenu) { actions }
                    .focused($focus, equals: .menu)
            }
            .onHover { isHovering = $0 }
            .contextMenu { actions }
            if expanded {
                Text(routine.prompt)
                    .font(.system(size: 12 * textScale))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                    .id("overview-routine-details-\(routine.id)")
            }
            if let error = item[key].error {
                ManagementError(message: error).padding(.leading, 38).padding(.bottom, 6)
            }
        }
        .task(id: snapshot?.requestedState) {
            if snapshot?.requestedState == "overview-routines" { item[key].expanded = true }
        }
        .task(id: runRequestedAt) {
            guard runRequestedAt != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { item.update(key) { $0.runRequestedAt = nil } }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Run Now", action: run).disabled(!canRun)
        Divider()
        Button("Delete Routine…", role: .destructive) {
            if let target = store.target { management.present(.deleteRoutine(target, routineId: routine.id)) }
        }
        .disabled(isRunning || !store.phase.isConnected)
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { item[key].expanded = value }
        if value { onExpand() }
    }

    private func run() {
        guard canRun else { return }
        item[key].isRunning = true
        item[key].runRequestedAt = nil
        item[key].error = nil
        Task { [key] in
            var requestedAt: Date?
            var failure: String?
            do {
                try await store.api.runRoutine(channelId: store.id, routineId: routine.id)
                requestedAt = .now
            } catch {
                failure = error.localizedDescription
            }
            item.update(key) {
                $0.isRunning = false
                $0.error = failure
                if let requestedAt { $0.runRequestedAt = requestedAt }
            }
        }
    }
}
