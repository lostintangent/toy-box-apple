import ChannelKit
import SwiftUI
import Testing
import ToyBoxUI
import UIKit
@testable import ChannelClient
@testable import ToyBoxMobile

@Suite("Mobile task rows")
@MainActor
struct TaskRowsTests {
    @Test func visibleTasksHaveStableDepthFirstRowIdentitiesAndOnlyRootGroupsHaveSpacing() throws {
        let rows = project(tree)
        #expect(rows.map(\.id) == [.task("root"), .task("child"), .task("grandchild"),
                                  .task("sibling"), .task("other")])
        #expect(rows.map(\.depth) == [0, 1, 2, 1, 0])
        #expect(rows.map(\.endsRoot) == [false, false, false, true, true])
        let children = try #require(tree[0].children)
        let grandchild = try #require(children[0].children?.first)
        #expect(rows.map(\.task) == [tree[0], children[0], grandchild, children[1], tree[1]])
    }

    @Test func closingAParentRetainsDescendantChoicesAndStatusChangesUseSharedDefaults() {
        let disclosure: [String: OverviewSession.Disclosure] = [
            "root": .init(status: "in_progress", expanded: false),
            "child": .init(status: "in_progress", expanded: false),
        ]
        let closed = project(tree, disclosure: disclosure)
        #expect(closed.map(\.id) == [.task("root"), .task("other")])
        #expect(closed.allSatisfy { $0.guides.isEmpty })
        var reopened = disclosure
        reopened["root"]?.expanded = true
        #expect(project(tree, disclosure: reopened).map(\.id)
                == [.task("root"), .task("child"), .task("sibling"), .task("other")])
        var changed = tree
        changed[0].status = "done"
        #expect(project(changed, disclosure: reopened).map(\.id) == [.task("root"), .task("other")])
        changed[0].status = "blocked"
        #expect(project(changed, disclosure: disclosure).map(\.id)
                == [.task("root"), .task("child"), .task("sibling"), .task("other")])
        #expect(disclosure["child"]?.expanded == false)
    }

    @Test(arguments: [263.99, 264, 264.01])
    func theActualReadingFloorControlsInlineRowsWithoutADeviceThreshold(width: CGFloat) {
        let child = ChannelTask(id: "child", title: "Child", ownerId: "owner")
        let parent = ChannelTask(id: "root", title: "Root", ownerId: "owner", children: [child])
        let rows = project([parent], width: width)
        if width < 264 {
            #expect(rows.map(\.id) == [.task("root"), .subtasks("root")])
            #expect(rows.allSatisfy { $0.guides.isEmpty && $0.depth == 0 })
        } else {
            #expect(rows.map(\.id) == [.task("root"), .task("child")])
            #expect(rows[1].depth == 1)
            #expect(rows[1].guides == [.init(depth: 0, isFirst: true, isLast: true)])
        }
    }

    @Test func scopedSubtasksStartAFreshTreeWithoutDanglingParentGuides() {
        let rows = project(tree, accessibility: true)
        #expect(rows.map(\.id) == [.task("root"), .subtasks("root"), .task("other")])
        #expect(rows.allSatisfy { $0.guides.isEmpty && $0.depth == 0 })
        let scoped = project(tree[0].children ?? [], accessibility: true)
        #expect(scoped.map(\.id) == [.task("child"), .subtasks("child"), .task("sibling")])
        #expect(scoped.allSatisfy { $0.guides.isEmpty && $0.depth == 0 })
        #expect(scoped.map(\.endsRoot) == [false, true, true])
    }

    @Test func guideSegmentsClearOnlyTheWholeChildGroupsEnds() {
        let rows = project(tree)
        #expect(rows[0].guides.isEmpty)
        #expect(rows[1].guides == [.init(depth: 0, isFirst: true, isLast: false)])
        #expect(rows[2].guides == [.init(depth: 1, isFirst: true, isLast: true),
                                  .init(depth: 0, isFirst: false, isLast: false)])
        #expect(rows[3].guides == [.init(depth: 0, isFirst: false, isLast: true)])
        #expect(rows[4].guides.isEmpty)
        #expect(rows[1].guides[0].bottomClearance == 0)
        #expect(rows[2].guides[1].topClearance == 0 && rows[2].guides[1].bottomClearance == 0)
        #expect(rows[3].guides[0].topClearance == 0)
    }

    @Test func eachRootKeepsItsOwnReadingBudgetAndTaskFactsRemainUnchanged() {
        let child = ChannelTask(id: "child", title: "Child", ownerId: "owner", artifactId: "artifact",
                                diff: .init(added: 1522, removed: 114),
                                startedAt: "2026-10-26T01:00:00Z", checkInAt: "2026-10-26T02:00:00Z")
        let parent = ChannelTask(id: "root", title: "Root", children: [child])
        let rows = project([parent, .init(id: "owned", title: "Owned", ownerId: "owner")])
        #expect(rows[0].layout.rootHasOwner == false && rows[1].layout.rootHasOwner == false)
        #expect(rows[2].layout.rootHasOwner)
        #expect(rows[1].task == child)
        #expect(project([]).isEmpty)
    }

    @Test func aHundredSixLevelTreesKeepEveryTaskAndItsStableIdentity() {
        func task(root: Int, depth: Int) -> ChannelTask {
            .init(id: "\(root)-\(depth)", title: String(repeating: "Task title ", count: 11),
                  children: depth < 5 ? [task(root: root, depth: depth + 1)] : nil)
        }
        let rows = project((0..<100).map { task(root: $0, depth: 0) })
        #expect(rows.count == 600 && Set(rows.map(\.id)).count == 600)
        #expect(rows.filter(\.endsRoot).count == 100)
        #expect(rows.filter { $0.depth == 5 }.count == 100)
        #expect(rows.allSatisfy { !$0.isSubtasks })
    }

    @Test(arguments: [1.0, 2.0, 3.0], [false, true])
    func segmentedGuidesRenderExactlyLikeOneContinuousGuide(scale: CGFloat, rightToLeft: Bool) throws {
        for scheme in [ColorScheme.light, .dark] {
            let segmented = VStack(spacing: 0) {
                ChannelTaskAncestryGuide(statusWidth: 16, topClearance: 4, bottomClearance: 0)
                    .frame(height: 44)
                ChannelTaskAncestryGuide(statusWidth: 16, topClearance: 0, bottomClearance: 0)
                    .frame(height: 88)
                ChannelTaskAncestryGuide(statusWidth: 16, topClearance: 0, bottomClearance: 4)
                    .frame(height: 44)
            }
            let whole = ChannelTaskAncestryGuide(statusWidth: 16).frame(height: 176)
            func pixels(_ view: some View) throws -> Data {
                let renderer = ImageRenderer(content: view
                    .frame(width: 60)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.displayScale, scale)
                    .environment(\.colorScheme, scheme)
                    .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight))
                renderer.scale = scale
                let image = try #require(renderer.uiImage?.cgImage)
                return try #require(image.dataProvider?.data) as Data
            }
            #expect(try pixels(segmented) == pixels(whole))
        }
    }

    @Test(arguments: [466.0, 669.0], [DynamicTypeSize.large, .accessibility5])
    func nativeListHasOneCellPerVisibleTaskAndScopedLink(width: CGFloat, size: DynamicTypeSize) async throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let session = OverviewSession(store: store)
        let viewer = ChannelArtifactSession(
            decodeImage: { _, _, _ in throw ChannelAttachmentError.invalidImage },
            download: { _, _ in throw URLError(.notConnectedToInternet) })
        let host = UIHostingController(rootView:
            NavigationStack {
                OverviewList {
                    Section {
                        OverviewTaskRows(tasks: tree, store: store, session: session)
                            .listRowInsets(.vertical, 0)
                    }
                }
                .navigationDestination(for: OverviewRoute.self) { _ in Text("Scoped subtasks") }
            }
            .environment(viewer)
            .transaction { $0.disablesAnimations = true }
            .dynamicTypeSize(size))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 2400))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let list = try #require(nativeList(in: host.view))
        let elements = MobileAutomationTree(windows: [window]).elements
        let taskIDs = Set(elements.filter { $0.identifier.hasPrefix("overview-task-") }.map(\.identifier))
        let scopedIDs = Set(elements.filter { $0.identifier.hasPrefix("overview-subtasks-") }.map(\.identifier))
        let visibleCount = taskIDs.count + scopedIDs.count
        #expect(list.numberOfItems(inSection: 0) == visibleCount)
        if scopedIDs.isEmpty {
            #expect(taskIDs == ["overview-task-root", "overview-task-child", "overview-task-grandchild",
                                "overview-task-sibling", "overview-task-other"])
            let frames = try (1...3).map {
                try #require(list.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))).frame
            }
            #expect(abs(frames[0].maxY - frames[1].minY) < 0.001)
            #expect(abs(frames[1].maxY - frames[2].minY) < 0.001)
        } else {
            #expect(taskIDs == ["overview-task-root", "overview-task-other"])
            #expect(scopedIDs == ["overview-subtasks-root"])
        }
        let parent = try #require(elements.first { $0.identifier == "overview-task-root" })
        let leaf = try #require(elements.first { $0.identifier == "overview-task-other" })
        #expect(parent.traits.contains(.button) && parent.value == "Expanded")
        #expect(leaf.traits.contains(.staticText) && !leaf.traits.contains(.button))
        session.taskDisclosure["root"] = .init(status: "in_progress", expanded: false)
        await Task.yield()
        host.view.layoutIfNeeded()
        #expect(list.numberOfItems(inSection: 0) == 2)
        session.taskDisclosure["root"] = .init(status: "in_progress", expanded: true)
        await Task.yield()
        host.view.layoutIfNeeded()
        #expect(list.numberOfItems(inSection: 0) == visibleCount)
    }

    private var tree: [ChannelTask] {
        [
            .init(id: "root", title: "Root", status: "in_progress", children: [
                .init(id: "child", title: "Child", status: "in_progress", children: [
                    .init(id: "grandchild", title: "Grandchild"),
                ]),
                .init(id: "sibling", title: "Sibling"),
            ]),
            .init(id: "other", title: "Other", status: "done"),
        ]
    }

    private func project(
        _ tasks: [ChannelTask], disclosure: [String: OverviewSession.Disclosure] = [:],
        width: CGFloat = 600, accessibility: Bool = false
    ) -> [OverviewTaskListRow] {
        OverviewTaskListRow.visibleRows(tasks: tasks, disclosure: disclosure) { root in
            .init(contentWidth: width, statusWidth: 16, titleGap: 6, ownerWidth: 20,
                  scaledReadingWidth: accessibility ? 640 : 192,
                  accessibility: accessibility, rootHasOwner: root.ownerId != nil)
        }
    }

    private func nativeList(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        return view.subviews.lazy.compactMap { nativeList(in: $0) }.first
    }
}
