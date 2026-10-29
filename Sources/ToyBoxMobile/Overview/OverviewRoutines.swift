import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct OverviewRoutinesSection: View {
    let store: ChannelStore
    let session: OverviewSession

    var body: some View {
        OverviewSectionRows(summary: .routines(store.routines.count), section: .routines, session: session) {
            if store.routines.isEmpty {
                Text("No routines").foregroundStyle(ChannelInk.secondary)
                    .modifier(OverviewListRowBoundary(isLast: true))
            } else {
                ForEach(store.routines) { routine in
                    OverviewRoutineRow(routine: routine, store: store, state: session.routine(routine.id),
                                       isLast: routine.id == store.routines.last?.id)
                }
            }
        }
    }
}

struct OverviewRoutineRow: View {
    let routine: ChannelRoutine
    let store: ChannelStore
    @Environment(AppModel.self) private var app
    @Environment(ManagementPresenter.self) private var management
    @Bindable var state: OverviewRoutineState
    let isLast: Bool
    private var pending: Bool { state.pending }
    private var requestedAt: Date? { state.requestedAt }
    private var recovery: ChannelManagementWriteRecovery { state.recovery }

    private var canRun: Bool { store.phase.isConnected && !pending && !recovery.blocksWrites }
    private var schedule: String { (try? cronSummary(routine.schedule)) ?? routine.schedule }
    private var contentEndsSection: Bool { isLast && recovery.error == nil && recovery.state == nil }

    var body: some View {
        DisclosureGroup(isExpanded: $state.expanded) {
            Text(routine.prompt).textSelection(.enabled)
            TimelineView(.everyMinute) { context in
                switch Result(catching: { try nextCronOccurrence(routine.schedule, from: context.date) }) {
                case .success(let date):
                    LabeledContent("Next run") {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(ChannelInk.secondary)
                    }
                case .failure:
                    Text("Next run unavailable").foregroundStyle(ChannelInk.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(routine.schedule).font(.footnote.monospaced())
                Text(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)
                    .font(.footnote).foregroundStyle(ChannelInk.secondary)
            }
            .textSelection(.enabled)
            Button("Run Now", systemImage: "play", action: run)
                .frame(minHeight: 44)
                .disabled(!canRun)
            Button("Delete Routine", systemImage: "trash", role: .destructive) {
                management.present(.deleteRoutine(channelId: store.id, routineId: routine.id))
            }
            .frame(minHeight: 44)
            .disabled(pending || !store.phase.isConnected)
            .modifier(OverviewListRowBoundary(isLast: contentEndsSection))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(routine.title).font(.body)
                Text(ChannelRoutineRunPresentation.label(schedule: schedule, pending: pending, requestedAt: requestedAt))
                    .font(.footnote).foregroundStyle(ChannelInk.secondary)
            }
            .frame(minHeight: 64, alignment: .leading)
        }
        .listRowSeparator(contentEndsSection && !state.expanded ? .hidden : .automatic, edges: .bottom)
        .contextMenu {
            Button("Run Now", systemImage: "play", action: run).disabled(!canRun)
            Button("Delete Routine", systemImage: "trash", role: .destructive) {
                management.present(.deleteRoutine(channelId: store.id, routineId: routine.id))
            }
            .disabled(pending || !store.phase.isConnected)
        }
        .task(id: requestedAt) {
            guard let requestedAt else { return }
            do { try await Task.sleep(for: .seconds(max(0, 4 + requestedAt.timeIntervalSinceNow))) }
            catch is CancellationError { return }
            catch { recovery.record(error); return }
            state.requestedAt = nil
        }
        if let error = recovery.error {
            ManagementError(message: error)
                .modifier(OverviewListRowBoundary(isLast: isLast && recovery.state == nil))
        }
        if let state = recovery.state {
            ManagementRecoveryNotice(state: state, reviewTitle: "I've Reviewed the Conversation",
                                     onCheck: { Task { await check(catalog: matchingCatalog) } },
                                     onReview: recovery.finishReview)
                .modifier(OverviewListRowBoundary(isLast: isLast))
        }
    }

    private var matchingCatalog: ChannelCatalogStore? {
        app.catalog.flatMap { $0.api.baseURL == store.api.baseURL ? $0 : nil }
    }

    private func run() {
        guard canRun else { return }
        state.pending = true
        state.requestedAt = nil
        recovery.clearError()
        let catalog = matchingCatalog
        Task {
            defer { state.pending = false }
            do {
                try await store.api.runRoutine(channelId: store.id, routineId: routine.id)
                state.requestedAt = .now
            } catch {
                if recovery.record(error) { await check(catalog: catalog) }
            }
        }
    }

    private func check(catalog: ChannelCatalogStore?) async {
        await recovery.check(catalog: catalog, channelId: store.id) { current in
            if current.channelWasDeleted { return "The channel is no longer present on the server." }
            return "Channel details have been refreshed. This routine may already have started. Review the current conversation before requesting another run."
        }
    }
}
