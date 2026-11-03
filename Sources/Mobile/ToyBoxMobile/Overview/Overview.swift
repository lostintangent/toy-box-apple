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

    /// Folded landscape stands the sheet's bar items in a leading vertical bar, which would move the
    /// close over the list. The sheet keeps its bar horizontal there, so the close stays trailing.
    func keepsHorizontalBar(hasLeadingVerticalBar: Bool) -> Bool {
        self == .sheet && hasLeadingVerticalBar
    }
}

enum OverviewRoute: Hashable {
    case subtasks(String)
}

enum OverviewSection: Hashable {
    case team, tasks, artifacts, routines
}

@MainActor @Observable
final class Overview {
    var placement = OverviewPlacement.sheet
    private(set) var isCompactSheetPresented = false
    @ObservationIgnored private var sessions: [ObjectIdentifier: ChannelOverview] = [:]

    func session(for store: ChannelStore) -> ChannelOverview {
        let key = ObjectIdentifier(store)
        if let session = sessions[key] { return session }
        let session = ChannelOverview(store: store)
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
final class ChannelOverview {
    struct Disclosure {
        /// The default the toggle was made against. A change to the default re-derives the disclosure.
        let expandedByDefault: Bool
        var expanded: Bool
    }

    @MainActor @Observable
    final class Routine {
        var expanded = false
        var pending = false
        var requestedAt: Date?
        let recovery = ChannelManagementWriteRecovery()
    }

    @MainActor @Observable
    final class Artifact {
        var pending = false
        let recovery = ChannelManagementWriteRecovery()

        func canRemove(connected: Bool) -> Bool { connected && !pending && !recovery.blocksWrites }
    }

    let store: ChannelStore
    var navigationPath: [OverviewRoute] = []
    var expandedSections: [OverviewSection: Bool] = [:]
    var purposeExpanded = false
    var previewError: String?
    var taskDisclosure: [String: Disclosure] = [:]
    var showsOnlyInProgressTasks = false
    var showsOnlyWorkingAgents = false
    @ObservationIgnored private var routines: [String: Routine] = [:]
    @ObservationIgnored private var artifacts: [String: Artifact] = [:]

    init(store: ChannelStore) { self.store = store }

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
                if taskDisclosure[task.id]?.expandedByDefault != task.isExpandedByDefault {
                    taskDisclosure[task.id] = Disclosure(expandedByDefault: task.isExpandedByDefault,
                                                         expanded: task.isExpandedByDefault)
                }
                visit(task.children ?? [])
            }
        }
        visit(tasks)
        taskDisclosure = taskDisclosure.filter { ids.contains($0.key) }
    }

    func routine(_ id: String) -> Routine {
        if let state = routines[id] { return state }
        let state = Routine()
        routines[id] = state
        return state
    }

    func artifact(_ id: String) -> Artifact {
        if let state = artifacts[id] { return state }
        let state = Artifact()
        artifacts[id] = state
        return state
    }
}
