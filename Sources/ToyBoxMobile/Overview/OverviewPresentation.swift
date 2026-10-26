import ChannelClient
import ChannelKit
import Observation
import SwiftUI

enum OverviewPlacement: Equatable {
    case sheet, inspector
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

    func move(to placement: OverviewPlacement) {
        guard self.placement != placement else { return }
        for session in sessions.values { session.prepareForPresentation() }
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
    var scrollPosition = ScrollPosition()
    @ObservationIgnored var scrollOffset: CGFloat = 0
    @ObservationIgnored private(set) var restorationOffset: CGFloat?
    @ObservationIgnored private var routines: [String: OverviewRoutineState] = [:]
    @ObservationIgnored private var taskScrolls: [String: OverviewTaskScroll] = [:]

    init(store: ChannelStore) { self.store = store }

    func prepareForPresentation() {
        restorationOffset = scrollOffset
        for scroll in taskScrolls.values { scroll.prepare() }
    }

    func prepareForTaskReveal() {
        expandedSections[.tasks] = true
        navigationPath = []
        restorationOffset = nil
        scrollPosition = ScrollPosition()
    }

    func isExpanded(_ section: OverviewSection) -> Bool { expandedSections[section] ?? true }

    func taskScroll(_ id: String) -> OverviewTaskScroll {
        if let scroll = taskScrolls[id] { return scroll }
        let scroll = OverviewTaskScroll()
        taskScrolls[id] = scroll
        return scroll
    }

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

    func restoreScroll() {
        guard let restorationOffset else { return }
        scrollPosition.scrollTo(y: restorationOffset)
        self.restorationOffset = nil
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
final class OverviewTaskScroll {
    var position = ScrollPosition()
    @ObservationIgnored var offset: CGFloat = 0
    @ObservationIgnored var restorationOffset: CGFloat?

    func prepare() { restorationOffset = offset }

    func restore() {
        guard let restorationOffset else { return }
        position.scrollTo(y: restorationOffset)
        self.restorationOffset = nil
    }
}

@MainActor @Observable
final class OverviewRoutineState {
    var expanded = false
    var pending = false
    var requestedAt: Date?
    let recovery = ChannelManagementWriteRecovery()
}
