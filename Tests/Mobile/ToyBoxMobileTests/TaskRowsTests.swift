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

    @Test func closingAParentRetainsDescendantChoicesAndOnlyDefaultChangesReDerive() throws {
        var disclosure = ChannelTask.Disclosure()
        disclosure.set(false, tree[0], key: "root")
        disclosure.set(false, try #require(tree[0].children?.first), key: "child")
        let closed = project(tree, disclosure: disclosure)
        #expect(closed.map(\.id) == [.task("root"), .task("other")])
        #expect(closed.allSatisfy { $0.guides.isEmpty })
        var reopened = disclosure
        reopened.set(true, tree[0], key: "root")
        #expect(project(tree, disclosure: reopened).map(\.id)
                == [.task("root"), .task("child"), .task("sibling"), .task("other")])
        var blocked = tree
        blocked[0].status = "blocked"
        #expect(blocked[0].isExpandedByDefault)
        #expect(project(blocked, disclosure: disclosure).map(\.id) == [.task("root"), .task("other")])
        var done = tree
        done[0].status = "done"
        // Work in progress anywhere below keeps a parent expanded, so the subtree must finish too.
        done[0].children?[0].status = "done"
        #expect(!done[0].isExpandedByDefault)
        #expect(project(done, disclosure: reopened).map(\.id) == [.task("root"), .task("other")])
    }

    @Test(arguments: [263.99, 264, 264.01])
    func theActualReadingFloorControlsInlineRowsWithoutADeviceThreshold(width: CGFloat) {
        let child = ChannelTask(id: "child", title: "Child", ownerId: "owner")
        let parent = ChannelTask(id: "root", title: "Root", status: "in_progress", ownerId: "owner", children: [child])
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

    @Test(arguments: [1, 2])
    func scopedTitlesUseTheRightSubtaskPlural(count: Int) throws {
        let parent = ChannelTask(id: "parent", title: "Parent", status: "in_progress", children:
            (0..<count).map { .init(id: "child-\($0)", title: "Child") })
        let row = try #require(project([parent], accessibility: true).first { $0.isSubtasks })
        #expect(row.subtasksTitle == (count == 1 ? "View 1 subtask" : "View 2 subtasks"))
    }

    @Test func inProgressFilterKeepsOnlyWorkInProgressBranchesAndTheirKeptChildren() {
        let rows = project(tree, showsOnlyInProgress: true)
        #expect(rows.map(\.id) == [.task("root"), .task("child")])
        #expect(rows.map(\.depth) == [0, 1])
        #expect(rows.map(\.endsRoot) == [false, true])
        #expect(rows[1].guides == [.init(depth: 0, isFirst: true, isLast: true)])
        #expect(project(tree).count == 5)
    }

    @Test func inProgressFilterLeavesDisclosureAloneAndKeepsCollapsedParentsCollapsed() {
        var collapsed = ChannelTask.Disclosure()
        collapsed.set(false, tree[0], key: "root")
        #expect(project(tree, disclosure: collapsed, showsOnlyInProgress: true).map(\.id) == [.task("root")])
        #expect(project(tree, disclosure: collapsed).map(\.id) == [.task("root"), .task("other")])
    }

    @Test func inProgressFilterCountsOnlyKeptSubtasksInTheScopedLink() throws {
        let parent = ChannelTask(id: "parent", title: "Parent", status: "in_progress", children: [
            .init(id: "active", title: "Active", status: "in_progress"),
            .init(id: "queued", title: "Queued"),
            .init(id: "later", title: "Later"),
        ])
        let kept = try #require(project([parent], accessibility: true, showsOnlyInProgress: true).first { $0.isSubtasks })
        #expect(kept.subtasksTitle == "View 1 subtask")
        let full = try #require(project([parent], accessibility: true).first { $0.isSubtasks })
        #expect(full.subtasksTitle == "View 3 subtasks")
    }

    @Test func aKeptParentWithNoKeptChildrenIsALeafWithNoSubtasksLink() {
        let parent = ChannelTask(id: "parent", title: "Parent", status: "in_progress", children: [
            .init(id: "first", title: "First", status: "done"),
            .init(id: "second", title: "Second", status: "done"),
        ])
        #expect(OverviewTaskListRow.visibleChildren(of: parent, showsOnlyInProgress: true).isEmpty)
        #expect(OverviewTaskListRow.visibleChildren(of: parent, showsOnlyInProgress: false).count == 2)
        #expect(project([parent], accessibility: true, showsOnlyInProgress: true).map(\.id) == [.task("parent")])
        #expect(project([parent], showsOnlyInProgress: true).map(\.id) == [.task("parent")])
    }

    @Test func inProgressFilterShowsNoRowsWhenNothingHoldsWork() {
        #expect(project([tree[1]], showsOnlyInProgress: true).isEmpty)
        #expect(project([], showsOnlyInProgress: true).isEmpty)
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
        let parent = ChannelTask(id: "root", title: "Root", status: "in_progress", children: [child])
        let rows = project([parent, .init(id: "owned", title: "Owned", ownerId: "owner")])
        #expect(rows[0].layout.rootHasOwner == false && rows[1].layout.rootHasOwner == false)
        #expect(rows[2].layout.rootHasOwner)
        #expect(rows[1].task == child)
        #expect(project([]).isEmpty)
    }

    @Test func aHundredSixLevelTreesKeepEveryTaskAndItsStableIdentity() {
        func task(root: Int, depth: Int) -> ChannelTask {
            .init(id: "\(root)-\(depth)", title: String(repeating: "Task title ", count: 11), status: "in_progress",
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
            func pixels(_ view: some View) throws -> [UInt8] {
                try ownBitmapPixels(view
                    .frame(width: 60)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.displayScale, scale)
                    .environment(\.colorScheme, scheme)
                    .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight), scale: scale)
            }
            #expect(try pixels(segmented) == pixels(whole))
        }
    }

    /// Draws into the test's own bitmap. `uiImage?.cgImage` returns an image-provider CGImage that rasterizes
    /// through an IOSurface on first draw, the path that failed CI (t510 and t603). The background is opaque,
    /// so a transparent pixel marks an incomplete render.
    private func ownBitmapPixels(_ content: some View, scale: CGFloat) throws -> [UInt8] {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var image: (width: Int, height: Int, pixels: [UInt8])?
        renderer.render(rasterizationScale: scale) { size, draw in
            let width = Int((size.width * scale).rounded(.up))
            let height = Int((size.height * scale).rounded(.up))
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.scaleBy(x: scale, y: scale)
                draw(context)
            }
            image = (width, height, pixels)
        }
        let result = try #require(image)
        let opaque = stride(from: 3, to: result.pixels.count, by: 4).allSatisfy { result.pixels[$0] == 255 }
        try #require(opaque, "Incomplete render: an opaque background left transparent pixels.")
        return result.pixels
    }

    @Test(arguments: [false, true])
    func taskPaddingTightensOnlyAtOrdinaryTextSizes(accessibility: Bool) {
        #expect(OverviewTaskMetrics.verticalPadding(accessibility: accessibility) == (accessibility ? 12 : 11))
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility1, .accessibility5])
    func theArtifactLineKeepsItsInternalGapAndUsesTheTaskOuterPadding(size: DynamicTypeSize) throws {
        let label = ImageRenderer(content: OverviewTaskArtifactLabel(title: "Plan").dynamicTypeSize(size))
        label.proposedSize = ProposedViewSize(width: 466, height: nil)
        label.scale = 3
        let content = ImageRenderer(content:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "doc.text")
                Text("Plan")
            }
            .font(.footnote)
            .dynamicTypeSize(size))
        content.scale = 3
        let labelHeight = try #require(label.uiImage).size.height
        let contentHeight = try #require(content.uiImage).size.height
        let outerPadding: CGFloat = size.isAccessibilitySize ? 12 : 11
        #expect(abs(labelHeight - contentHeight - ChannelOverviewFactsLayout.titleGap - outerPadding) < 0.5)
    }

    @Test func aScopedNativeAccessoryCannotChangeTheRootReadingWidth() async throws {
        func task(depth: Int) -> ChannelTask {
            .init(id: "depth-\(depth)", title: "Keep the six-level task hierarchy", status: "in_progress",
                  children: depth < 5 ? [task(depth: depth + 1)] : nil)
        }
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let session = ChannelOverview(store: store)
        let viewer = ChannelArtifactSession(
            decodeImage: { _, _, _ in throw ChannelAttachmentError.invalidImage },
            download: { _, _ in throw URLError(.notConnectedToInternet) })
        let host = UIHostingController(rootView:
            NavigationStack {
                OverviewList {
                    Section {
                        OverviewTaskRows(tasks: [task(depth: 0)], store: store, session: session)
                            .listRowInsets(.vertical, 0)
                    }
                }
                .navigationDestination(for: OverviewRoute.self) { _ in Text("Scoped subtasks") }
            }
            .environment(viewer)
            .environment(\.horizontalSizeClass, .compact)
            .dynamicTypeSize(.large))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 354, height: 1400))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let list = try #require(nativeList(in: host.view))
        let expected = Set((0...4).map { "overview-task-depth-\($0)" } + ["overview-subtasks-depth-4"])
        func rowIDs() -> Set<String> {
            Set(MobileAutomationTree(windows: [window]).elements
                .filter { $0.identifier.hasPrefix("overview-task-") || $0.identifier.hasPrefix("overview-subtasks-") }
                .map(\.identifier))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while rowIDs() != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            host.view.layoutIfNeeded()
        }
        #expect(rowIDs() == expected)
        #expect(list.numberOfItems(inSection: 0) == expected.count)
        #expect(MobileAutomationTree(windows: [window]).matching("overview-subtasks-depth-4").first?.label
                == "View 1 subtask of Keep the six-level task hierarchy")
        for _ in 0..<4 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
            #expect(rowIDs() == expected)
            #expect(list.numberOfItems(inSection: 0) == expected.count)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark], [DynamicTypeSize.large, .accessibility5])
    func taskAndScopedRowsPreserveTheInheritedSurface(scheme: ColorScheme, size: DynamicTypeSize) async throws {
        let surface = scheme == .light ? Color.red : Color.blue
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let session = ChannelOverview(store: store)
        let viewer = ChannelArtifactSession(
            decodeImage: { _, _, _ in throw ChannelAttachmentError.invalidImage },
            download: { _, _ in throw URLError(.notConnectedToInternet) })
        let host = UIHostingController(rootView:
            NavigationStack {
                OverviewList {
                    Section {
                        OverviewTaskRows(tasks: tree, store: store, session: session)
                            .listRowInsets(.vertical, 0)
                        Text("Reference surface")
                            .frame(minHeight: 44)
                    }
                }
                .background(surface)
                .backgroundStyle(surface)
                .navigationDestination(for: OverviewRoute.self) { _ in Text("Scoped subtasks") }
            }
            .environment(viewer)
            .environment(\.colorScheme, scheme)
            .dynamicTypeSize(size)
            .transaction { $0.disablesAnimations = true })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 2400))
        window.overrideUserInterfaceStyle = scheme == .light ? .light : .dark
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let list = try #require(nativeList(in: host.view))
        let expected = size.isAccessibilitySize ? 4 : 6
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while list.numberOfItems(inSection: 0) != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            host.view.layoutIfNeeded()
        }
        try #require(list.numberOfItems(inSection: 0) == expected)
        host.view.layoutIfNeeded()

        func backgroundPixel(item: Int) throws -> [UInt8] {
            let frame = try #require(list.layoutAttributesForItem(at: IndexPath(item: item, section: 0))).frame
            let point = list.convert(CGPoint(x: frame.minX + 2, y: frame.midY), to: window)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format)
                .image { context in
                    context.cgContext.translateBy(x: -point.x, y: -point.y)
                    window.layer.render(in: context.cgContext)
                }.cgImage)
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            var bytes = [UInt8](repeating: 0, count: 4)
            try bytes.withUnsafeMutableBytes { storage in
                let context = try #require(CGContext(
                    data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes
        }

        let reference = try backgroundPixel(item: expected - 1)
        #expect(reference[3] == 255)
        #expect(Set(reference.prefix(3)).count > 1)
        for item in 0..<(expected - 1) {
            #expect(try backgroundPixel(item: item) == reference,
                    "Task or scoped row \(item) must match the unmodified reference row")
        }
    }

    @Test(arguments: DisclosureChange.allCases, [false, true])
    func taskDisclosureDoesNotAnimateTapsOrStatusChanges(change: DisclosureChange, scoped: Bool) async throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let session = ChannelOverview(store: store)
        let record = DisclosureTransactions()
        let size = change.size
        var tasks = tree
        func channelTasks(_ tasks: [ChannelTask]) -> [ChannelTask] {
            scoped ? [.init(id: "scope", title: "Parent", children: tasks)] : tasks
        }
        var state = ChannelState(
            revision: 1,
            channel: .init(id: "channel", name: "Workshop", model: .init(provider: "test", name: "test"),
                           tasks: channelTasks(tasks), updatedAt: "2026-10-26T00:00:00Z"),
            lead: .lead(id: "channel", profile: .init(name: "Lead", role: "Coordinator",
                                                    avatar: .init(mark: "M4 12H20", color: "#123456"))))
        _ = try store.apply(.init(type: "snapshot", state: state))
        session.reconcileTasks(store.tasks)
        let viewer = ChannelArtifactSession(
            decodeImage: { _, _, _ in throw ChannelAttachmentError.invalidImage },
            download: { _, _ in throw URLError(.notConnectedToInternet) })
        let host = UIHostingController(rootView:
            DisclosureTransactionScene(task: tree[0], store: store, session: session,
                                       accessibility: size.isAccessibilitySize,
                                       statusDriven: change.isStatusDriven, scoped: scoped, record: record)
                .environment(viewer)
                .environment(Overview()).environment(ChannelInteraction())
                .environment(ManagementPresenter())
                .dynamicTypeSize(size))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 1400))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        record.entries.removeAll()
        if change.isStatusDriven {
            state.revision += 1
            tasks[0].status = "done"
            tasks[0].children?[0].status = "done"
            state.channel.tasks = channelTasks(tasks)
            _ = try store.apply(.init(type: "snapshot", state: state))
        } else {
            let row = try #require(MobileAutomationTree(windows: [window]).matching("overview-task-root").first)
            let collapse = try #require(row.actions.first { $0.name == "Collapse" })
            #expect(row.perform(collapse))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while record.entries.allSatisfy(\.expanded), ContinuousClock.now < deadline {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
        let transaction = try #require(record.entries.first { !$0.expanded })
        let root = try #require(session.task("root"))
        #expect(!session.taskDisclosure.isExpanded(root, key: "root"))
        #expect(transaction.animation == nil)
    }

    @Test(arguments: [466.0, 669.0], [DynamicTypeSize.large, .accessibility5])
    func nativeListHasOneCellPerVisibleTaskAndScopedLink(width: CGFloat, size: DynamicTypeSize) async throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let session = ChannelOverview(store: store)
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
        #expect(elements.filter { taskIDs.contains($0.identifier) || scopedIDs.contains($0.identifier) }
            .allSatisfy { $0.frame.height >= 44 })
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
        session.taskDisclosure.set(false, tree[0], key: "root")
        await Task.yield()
        host.view.layoutIfNeeded()
        #expect(list.numberOfItems(inSection: 0) == 2)
        session.taskDisclosure.set(true, tree[0], key: "root")
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
        _ tasks: [ChannelTask], disclosure: ChannelTask.Disclosure = .init(),
        width: CGFloat = 600, accessibility: Bool = false, showsOnlyInProgress: Bool = false
    ) -> [OverviewTaskListRow] {
        OverviewTaskListRow.visibleRows(tasks: tasks, disclosure: disclosure,
                                        showsOnlyInProgress: showsOnlyInProgress) { root in
            .init(contentWidth: width, statusWidth: 16, titleGap: 6, ownerWidth: 20,
                  scaledReadingWidth: accessibility ? 640 : 192,
                  accessibility: accessibility, rootHasOwner: root.ownerId != nil)
        }
    }

    private func nativeList(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        return view.subviews.lazy.compactMap { nativeList(in: $0) }.first
    }

    enum DisclosureChange: CaseIterable {
        case largeTap, ax1Tap, ax5Tap, largeStatus, ax1Status, ax5Status

        var size: DynamicTypeSize {
            switch self {
            case .largeTap, .largeStatus: .large
            case .ax1Tap, .ax1Status: .accessibility1
            case .ax5Tap, .ax5Status: .accessibility5
            }
        }

        var isStatusDriven: Bool {
            switch self {
            case .largeStatus, .ax1Status, .ax5Status: true
            case .largeTap, .ax1Tap, .ax5Tap: false
            }
        }
    }

    private final class DisclosureTransactions {
        var entries: [(expanded: Bool, animation: Animation?)] = []
    }

    private struct DisclosureTransactionScene: View {
        let task: ChannelTask
        let store: ChannelStore
        @Bindable var session: ChannelOverview
        let accessibility: Bool
        let statusDriven: Bool
        let scoped: Bool
        let record: DisclosureTransactions

        var body: some View {
            VStack {
                if scoped {
                    NavigationStack {
                        OverviewSubtasksScreen(parentID: "scope", store: store, session: session)
                    }
                } else if statusDriven {
                    OverviewView(store: store, session: session, placement: .sheet)
                        .environment(ChannelFollowController())
                } else {
                    OverviewTaskNode(task: task, store: store, session: session, depth: 0,
                                     layout: .init(contentWidth: 466, statusWidth: 16, titleGap: 6,
                                                   ownerWidth: 20, scaledReadingWidth: 192,
                                                   accessibility: accessibility, rootHasOwner: false))
                }
                DisclosureTransactionProbe(
                    expanded: session.task(task.id).map { session.taskDisclosure.isExpanded($0, key: $0.id) } ?? false,
                    record: record)
                    .frame(height: 0)
            }
        }
    }

    private struct DisclosureTransactionProbe: UIViewRepresentable {
        let expanded: Bool
        let record: DisclosureTransactions

        func makeUIView(context: Context) -> UIView { UIView() }

        func updateUIView(_ uiView: UIView, context: Context) {
            record.entries.append((expanded, context.transaction.animation))
        }
    }
}
