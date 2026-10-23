import ChannelClient
import ChannelKit
import Foundation
import SwiftUI

/// A routine shares the artifact geometry, with its prompt and next run disclosed in place.
struct OverviewRoutineRow: View {
    private enum Focus { case row, menu }

    @Environment(AppModel.self) private var app
    @Environment(ManagementPresenter.self) private var management
    @Environment(\.windowSnapshot) private var snapshot
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let routine: ChannelRoutine
    let store: ChannelStore
    let onExpand: () -> Void
    @ViewState private var expanded = false
    @ViewState private var isRunning = false
    @ViewState private var runRequestedAt: Date?
    @ViewState private var recovery = ManagementWriteRecovery()
    @ViewState private var isHovering = false
    @FocusState private var focus: Focus?

    private var canRun: Bool { !isRunning && !recovery.blocksWrites && store.phase.isLive }
    private var showsMenu: Bool { isHovering || focus != nil || voiceOver }
    private var scheduleSummary: String { (try? cronSummary(routine.schedule)) ?? routine.schedule }
    private var scheduleLine: String {
        if isRunning { return "Requesting run…" }
        if runRequestedAt != nil { return "Run requested" }
        return scheduleSummary
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
                .accessibilityHint(expanded ? "Hides the prompt and next run" : "Shows the prompt and next run")
                .accessibilityActions { actions }
                OverviewRowMenu(title: "Actions for \(routine.title)", isVisible: showsMenu) { actions }
                    .focused($focus, equals: .menu)
            }
            .onHover { isHovering = $0 }
            .contextMenu { actions }
            if expanded {
                TimelineView(.everyMinute) { context in
                    details(next: Result { try nextCronOccurrence(routine.schedule, from: context.date) })
                }
                .padding(.leading, 38)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .id("overview-routine-details-\(routine.id)")
            }
            if let error = recovery.error {
                ManagementError(message: error).padding(.leading, 38).padding(.bottom, 6)
            }
            if let state = recovery.state {
                ManagementRecoveryNotice(
                    state: state, reviewTitle: "I've Reviewed the Conversation",
                    onCheck: { Task { await checkCurrentState() } },
                    onReview: recovery.finishReview)
                .padding(.leading, 38)
                .padding(.bottom, 6)
            }
        }
        .task(id: snapshot?.requestedState) {
            if snapshot?.requestedState == "overview-routines" { expanded = true }
        }
        .task(id: runRequestedAt) {
            guard runRequestedAt != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { runRequestedAt = nil }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Run Now", action: run).disabled(!canRun)
        Divider()
        Button("Delete Routine…", role: .destructive) {
            management.present(.deleteRoutine(channelId: store.id, routineId: routine.id))
        }
        .disabled(isRunning || !store.phase.isLive)
    }

    private func details(next: Result<Date, Error>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(routine.prompt)
                .font(.system(size: 12 * textScale))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow {
                    Text("Next run").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    switch next {
                    case .success(let date):
                        Text(Self.nextRunFormatter.string(from: date))
                            .help(date.formatted(date: .complete, time: .standard))
                    case .failure(let failure):
                        Text("Unavailable")
                            .foregroundStyle(.secondary)
                            .help(failure.localizedDescription)
                            .accessibilityLabel("Next run unavailable")
                    }
                }
                GridRow {
                    Text("Schedule").foregroundStyle(.secondary)
                    Text("\(Text(routine.schedule).font(.system(size: 11 * textScale, design: .monospaced)))\(Text(" · \(Self.timeZoneName)").foregroundStyle(.secondary))")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 11 * textScale))
        }
    }

    private static let nextRunFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static var timeZoneName: String {
        TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded = value }
        if value { onExpand() }
    }

    private func run() {
        guard canRun else { return }
        isRunning = true
        runRequestedAt = nil
        recovery.clearError()
        Task {
            defer { isRunning = false }
            do {
                try await store.api.runRoutine(channelId: store.id, routineId: routine.id)
                runRequestedAt = .now
            } catch {
                if recovery.record(error) { await checkCurrentState() }
            }
        }
    }

    private func checkCurrentState() async {
        await recovery.check(catalog: app.catalog, channelId: store.id) { current in
            if current.channelWasDeleted {
                return "The channel is no longer present on the server."
            }
            return "Channel details have been refreshed. This routine may already have started. Review the current conversation before requesting another run."
        }
    }
}
