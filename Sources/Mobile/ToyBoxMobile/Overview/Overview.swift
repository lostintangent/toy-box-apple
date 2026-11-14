import ChannelClient
import ChannelKit
import Observation
import SwiftUI
import ToyBoxUI

enum OverviewPlacement: Equatable {
    case sheet, column

    /// The column's fixed width, the narrowest readers kept shrinking it to.
    static let columnWidth: CGFloat = 280

    /// The column takes room only on scenes at least 716 points wide, so the conversation keeps more
    /// than the Mac's 420 points beside it as it opens. On the Duo that's unfolded landscape. Unfolded
    /// portrait also reports a regular size class, so the scene's width decides.
    static let columnSceneWidth: CGFloat = 716

    /// The column covers the detail's trailing corner, so it also needs regular height, where the
    /// channel's Overview button stands in the trailing vertical bar beside it. A compact-height scene
    /// as wide, like a Pro Max in landscape, keeps a horizontal bar whose Overview button the column
    /// would cover.
    init(sceneWidth: CGFloat, sizeClass: UserInterfaceSizeClass?, verticalSizeClass: UserInterfaceSizeClass?) {
        self = sizeClass == .regular && verticalSizeClass == .regular && sceneWidth >= Self.columnSceneWidth
            ? .column : .sheet
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

    /// The landscape column has no close of its own. Only Overview's presence shows it, which the
    /// Overview button owns, like the sidebar's, so no rotation, fold or unfold opens or closes it.
    func showsColumn(for interaction: ChannelInteraction) -> Bool {
        placement == .column && interaction.isInspectorPresented && !interaction.isArtifactViewerPresented
    }

    /// A screen over Overview holds it where it is, so a rotation can't hand the screen to another
    /// presenter. Overview takes the scene's latest placement when the screen closes.
    @ObservationIgnored var isHeld = false {
        didSet { if oldValue, !isHeld { move(to: scenePlacement) } }
    }
    @ObservationIgnored private var scenePlacement = OverviewPlacement.sheet

    func move(to placement: OverviewPlacement) {
        scenePlacement = placement
        guard !isHeld, self.placement != placement else { return }
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
    @MainActor @Observable
    final class Routine {
        var expanded = false
        var pending = false
        var requestedAt: Date?
        var error: String?
    }

    @MainActor @Observable
    final class Artifact {
        var pending = false
        var error: String?

        func canRemove(connected: Bool) -> Bool { connected && !pending }
    }

    let store: ChannelStore
    var navigationPath: [OverviewRoute] = []
    var expandedSections: [OverviewSection: Bool] = [:]
    var purposeExpanded = false
    /// Keyed by task ID, so a parent's disclosure is the same inline and on its subtasks screen.
    var taskDisclosure = ChannelTask.Disclosure()
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
        taskDisclosure.reconcile(tasks.map { ($0.id, $0) }) { $1.id }
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
