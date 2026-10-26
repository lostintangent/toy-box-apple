import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct OverviewRoutinesSection: View {
    let store: ChannelStore

    var body: some View {
        Section("Routines · \(store.routines.count)") {
            if store.routines.isEmpty {
                Text("No routines").foregroundStyle(.secondary)
            } else {
                ForEach(store.routines) { OverviewRoutineRow(routine: $0, store: store) }
            }
        }
    }
}

private struct OverviewRoutineRow: View {
    let routine: ChannelRoutine
    let store: ChannelStore
    @Environment(AppModel.self) private var app
    @Environment(ManagementPresenter.self) private var management
    @ViewState private var expanded = false
    @ViewState private var pending = false
    @ViewState private var requestedAt: Date?
    @ViewState private var recovery = ChannelManagementWriteRecovery()

    private var canRun: Bool { store.phase.isLive && !pending && !recovery.blocksWrites }
    private var schedule: String { (try? cronSummary(routine.schedule)) ?? routine.schedule }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(routine.prompt).textSelection(.enabled)
            TimelineView(.everyMinute) { context in
                switch Result(catching: { try nextCronOccurrence(routine.schedule, from: context.date) }) {
                case .success(let date):
                    LabeledContent("Next run", value: date.formatted(date: .abbreviated, time: .shortened))
                case .failure:
                    Text("Next run unavailable").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(routine.schedule).font(.footnote.monospaced())
                Text(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            Button("Run Now", systemImage: "play", action: run)
                .frame(minHeight: 44)
                .disabled(!canRun)
            Button("Delete Routine", systemImage: "trash", role: .destructive) {
                management.present(.deleteRoutine(channelId: store.id, routineId: routine.id))
            }
            .frame(minHeight: 44)
            .disabled(pending || !store.phase.isLive)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(routine.title).font(.body)
                Text(pending ? "Requesting run…" : requestedAt != nil ? "Run requested" : schedule)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(minHeight: 64, alignment: .leading)
        }
        .contextMenu {
            Button("Run Now", systemImage: "play", action: run).disabled(!canRun)
            Button("Delete Routine", systemImage: "trash", role: .destructive) {
                management.present(.deleteRoutine(channelId: store.id, routineId: routine.id))
            }
            .disabled(pending || !store.phase.isLive)
        }
        .task(id: requestedAt) {
            guard let requestedAt else { return }
            do { try await Task.sleep(for: .seconds(max(0, 4 + requestedAt.timeIntervalSinceNow))) }
            catch is CancellationError { return }
            catch { recovery.record(error); return }
            self.requestedAt = nil
        }
        if let error = recovery.error { ManagementError(message: error) }
        if let state = recovery.state {
            ManagementRecoveryNotice(state: state, reviewTitle: "I've Reviewed the Conversation",
                                     onCheck: { Task { await check(catalog: matchingCatalog) } },
                                     onReview: recovery.finishReview)
        }
    }

    private var matchingCatalog: ChannelCatalogStore? {
        app.catalog.flatMap { $0.api.baseURL == store.api.baseURL ? $0 : nil }
    }

    private func run() {
        guard canRun else { return }
        pending = true
        requestedAt = nil
        recovery.clearError()
        let catalog = matchingCatalog
        Task {
            defer { pending = false }
            do {
                try await store.api.runRoutine(channelId: store.id, routineId: routine.id)
                requestedAt = .now
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
