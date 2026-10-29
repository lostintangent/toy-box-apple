import ChannelClient
import ChannelKit
import Observation
import SwiftUI
import ToyBoxUI

enum OverviewPlacement: Equatable {
    case sheet, inspector

    static let columnWidth: CGFloat = 296

    /// The column takes room only where the conversation keeps the Mac's 420 points beside it, which
    /// on the Duo is unfolded landscape. Unfolded portrait also reports a regular size class, so the
    /// scene's width decides.
    init(sceneWidth: CGFloat, sizeClass: UserInterfaceSizeClass?) {
        self = sizeClass == .regular && sceneWidth >= Self.columnWidth + 420 ? .inspector : .sheet
    }
}

enum OverviewRoute: Hashable {
    case agent(String)
    case subtasks(String)
}

enum OverviewSection: Hashable {
    case team, tasks, artifacts, routines
}

@MainActor @Observable
final class OverviewPresentation {
    var placement = OverviewPlacement.sheet
    private(set) var isCompactSheetPresented = false
    @ObservationIgnored private var sessions: [ObjectIdentifier: OverviewSession] = [:]

    func session(for store: ChannelStore) -> OverviewSession {
        let key = ObjectIdentifier(store)
        if let session = sessions[key] { return session }
        let session = OverviewSession(store: store)
        sessions[key] = session
        return session
    }

    /// The landscape column has no close of its own. The Overview button and Close Overview own its
    /// presence, like the sidebar's. SwiftUI writes `false` while the columns reflow during a
    /// rotation or fold, so the column never writes back.
    func columnBinding(for interaction: ChannelInteraction?) -> Binding<Bool> {
        Binding(get: { [self] in
            placement == .inspector && interaction?.isInspectorPresented == true
                && interaction?.isArtifactViewerPresented != true
        }, set: { _ in })
    }

    func move(to placement: OverviewPlacement) {
        guard self.placement != placement else { return }
        self.placement = placement
    }

    func compactSheetDidAppear() { isCompactSheetPresented = true }

    func compactSheetDidDismiss(isRequested: Bool) {
        guard placement != .sheet || !isRequested else { return }
        isCompactSheetPresented = false
    }

    func reset() { sessions = [:] }
}

@MainActor @Observable
final class OverviewSession {
    struct Disclosure {
        let status: String
        var expanded: Bool
    }

    let store: ChannelStore
    var navigationPath: [OverviewRoute] = []
    var expandedSections: [OverviewSection: Bool] = [:]
    var purposeExpanded = false
    var previewError: String?
    var taskDisclosure: [String: Disclosure] = [:]
    @ObservationIgnored private var routines: [String: OverviewRoutineState] = [:]

    init(store: ChannelStore) { self.store = store }

    func prepareForTaskReveal() {
        expandedSections[.tasks] = true
        navigationPath = []
    }

    func isExpanded(_ section: OverviewSection) -> Bool { expandedSections[section] ?? true }

    func task(_ id: String) -> ChannelTask? {
        Self.task(id, in: store.tasks)
    }

    static func task(_ id: String, in tasks: [ChannelTask]) -> ChannelTask? {
        for task in tasks {
            if task.id == id { return task }
            if let found = Self.task(id, in: task.children ?? []) { return found }
        }
        return nil
    }

    func reconcileTasks(_ tasks: [ChannelTask]) {
        var ids = Set<String>()
        @MainActor func visit(_ tasks: [ChannelTask]) {
            for task in tasks {
                ids.insert(task.id)
                if taskDisclosure[task.id]?.status != task.status {
                    taskDisclosure[task.id] = Disclosure(status: task.status, expanded: task.isExpandedByDefault)
                }
                visit(task.children ?? [])
            }
        }
        visit(tasks)
        taskDisclosure = taskDisclosure.filter { ids.contains($0.key) }
    }

    func routine(_ id: String) -> OverviewRoutineState {
        if let state = routines[id] { return state }
        let state = OverviewRoutineState()
        routines[id] = state
        return state
    }
}

@MainActor @Observable
final class OverviewRoutineState {
    var expanded = false
    var pending = false
    var requestedAt: Date?
    let recovery = ChannelManagementWriteRecovery()
}
