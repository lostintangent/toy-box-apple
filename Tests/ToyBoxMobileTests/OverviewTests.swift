import ChannelKit
import Foundation
import Observation
import Testing
import SwiftUI
import ToyBoxUI
import UIKit
@testable import ChannelClient
@testable import ToyBoxMobile
@testable import ToyBoxMobileIntegrations

@Suite("Mobile Overview")
@MainActor
struct OverviewTests {
    @Test func bothFollowMenusUseTheSameLabelsAndEnabledStates() {
        let available = ChannelFollowAction.State.available
        let unavailable = ChannelFollowAction.State.unavailable
        let starting = ChannelFollowAction.State.starting
        let following = ChannelFollowAction.State.following
        #expect(available.title == "Follow This Channel")
        #expect(unavailable.title == available.title)
        #expect(available.systemImage == "dot.radiowaves.left.and.right")
        #expect(available.isEnabled)
        #expect(!unavailable.isEnabled)
        #expect(starting.title == "Starting…")
        #expect(!starting.isEnabled)
        #expect(following.title == "Stop Following")
        #expect(following.systemImage == "stop.circle")
        #expect(following.isEnabled)
    }

    @Test func presentationChangesKeepTheSameOverviewStateAndScrollIntent() throws {
        let api = try ChannelAPI(serverURL: "https://fixture.example")
        let store = ChannelStore(id: "channel", api: api)
        let presentation = OverviewPresentation()
        let session = presentation.session(for: store)
        session.navigationPath = [.agent("agent")]
        session.purposeExpanded = true
        session.taskDisclosure["task"] = .init(status: "in_progress", expanded: false)
        session.scrollOffset = 244
        session.routine("routine").expanded = true
        session.routine("routine").pending = true
        presentation.compactSheetDidAppear()
        presentation.move(to: .inspector)
        #expect(presentation.isCompactSheetPresented)
        presentation.move(to: .sheet)
        #expect(presentation.session(for: store) === session)
        #expect(session.navigationPath == [.agent("agent")])
        #expect(session.purposeExpanded)
        #expect(session.taskDisclosure["task"]?.expanded == false)
        #expect(session.restorationOffset == 244)
        #expect(session.routine("routine").expanded)
        #expect(session.routine("routine").pending)
        #expect(presentation.session(for: ChannelStore(id: store.id, api: api)) !== session)
    }

    @Test func compactCoverageEndsOnDismissalAndObsoleteDismissalKeepsTheRequestedReplacementCovered() {
        let presentation = OverviewPresentation()
        presentation.compactSheetDidAppear()
        presentation.move(to: .inspector)
        #expect(presentation.isCompactSheetPresented)
        presentation.compactSheetDidDismiss(isRequested: true)
        #expect(!presentation.isCompactSheetPresented)
        presentation.move(to: .sheet)
        presentation.compactSheetDidAppear()
        presentation.compactSheetDidDismiss(isRequested: true)
        #expect(presentation.isCompactSheetPresented)
        presentation.compactSheetDidDismiss(isRequested: false)
        #expect(!presentation.isCompactSheetPresented)
    }

    @Test func tasksRevealReplacesQueuedScrollRestorationAndAgentNavigation() throws {
        let api = try ChannelAPI(serverURL: "https://fixture.example")
        let session = OverviewSession(store: ChannelStore(id: "channel", api: api))
        session.navigationPath = [.agent("agent")]
        session.scrollPosition.scrollTo(point: CGPoint(x: 0, y: 120))
        #expect(session.scrollPosition.point?.y == 120)
        session.scrollOffset = 244
        session.prepareForPresentation()
        #expect(session.restorationOffset == 244)
        session.prepareForTaskReveal()
        session.restoreScroll()
        #expect(session.navigationPath.isEmpty)
        #expect(session.restorationOffset == nil)
        #expect(session.scrollPosition.point == nil)
    }

    @Test func managementReconstructionRetainsEntriesPendingAndFocus() throws {
        try withModel { app in
            let catalog = try #require(app.catalog)
            let sessions = ManagementSessions()
            let flow = ManagementFlow.addMember(channelId: "channel", name: "Initial")
            let draft = sessions.session(for: flow, catalog: catalog)
            draft.name = "Edited"
            draft.role = "First line\nSecond line"
            draft.pending = true
            let pendingSince = try #require(draft.pendingSince)
            draft.pending = true
            draft.focus = .role
            let rebuilt = sessions.session(for: flow, catalog: catalog)
            #expect(rebuilt === draft)
            #expect(rebuilt.name == "Edited")
            #expect(rebuilt.role == "First line\nSecond line")
            #expect(rebuilt.pending && rebuilt.focus == .role)
            #expect(rebuilt.pendingSince == pendingSince)
            rebuilt.pending = false
            #expect(rebuilt.pendingSince == nil)
        }
    }

    @Test func taskReadingBudgetScopesBelowTheFloorAndKeepsEqualityInline() {
        func layout(_ width: CGFloat) -> OverviewTaskReadingLayout {
            .init(contentWidth: width, statusWidth: 16, titleGap: 6, ownerWidth: 20,
                  scaledReadingWidth: 192, accessibility: false, rootHasOwner: true)
        }
        #expect(layout(263.99).canInlineChildren(ofDepth: 0, haveOwner: true) == false)
        #expect(layout(264).canInlineChildren(ofDepth: 0, haveOwner: true))
        #expect(layout(264.01).canInlineChildren(ofDepth: 0, haveOwner: true))
        #expect(layout(264).indent == 22 && layout(264).readingFloor == 192)
        #expect(layout(180).readingFloor == 130)
        #expect(!layout(180).canInlineChildren(ofDepth: 0, haveOwner: true))
        #expect(!layout(0).canInlineChildren(ofDepth: 0, haveOwner: false))
        let accessible = OverviewTaskReadingLayout(
            contentWidth: 360, statusWidth: 24, titleGap: 8, ownerWidth: 28,
            scaledReadingWidth: 640, accessibility: true, rootHasOwner: true)
        #expect(accessible.indent == 32 && accessible.readingFloor == 360)
        #expect(accessible.titleWidth(depth: 0, hasOwner: true) == 360)
        #expect(!accessible.canInlineChildren(ofDepth: 0, haveOwner: true))
    }

    @Test func closingParentsAndMovingPresentationRetainChildChoicesRoutesAndScopedOffsets() throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let session = OverviewSession(store: store)
        var tasks: [ChannelTask] = [
            .init(id: "parent", title: "Parent", status: "in_progress", children: [
                .init(id: "child", title: "Child", status: "in_progress", children: [
                    .init(id: "leaf", title: "Leaf", status: "pending")
                ])
            ])
        ]
        session.reconcileTasks(tasks)
        session.taskDisclosure["child"] = .init(status: "in_progress", expanded: false)
        session.taskDisclosure["parent"] = .init(status: "in_progress", expanded: false)
        session.reconcileTasks(tasks)
        session.taskDisclosure["parent"] = .init(status: "in_progress", expanded: true)
        #expect(session.taskDisclosure["child"]?.expanded == false)
        tasks[0].status = "done"
        session.reconcileTasks(tasks)
        #expect(session.taskDisclosure["parent"]?.expanded == false)
        #expect(session.taskDisclosure["child"]?.expanded == false)
        tasks[0].status = "in_progress"
        session.reconcileTasks(tasks)
        #expect(session.taskDisclosure["parent"]?.expanded == true)
        #expect(session.taskDisclosure["child"]?.expanded == false)
        session.navigationPath = [.subtasks("parent"), .subtasks("child")]
        let scroll = session.taskScroll("child")
        scroll.offset = 244
        session.expandedSections[.team] = false
        session.prepareForPresentation()
        #expect(session.taskScroll("child") === scroll && scroll.restorationOffset == 244)
        #expect(session.navigationPath == [.subtasks("parent"), .subtasks("child")])
        #expect(!session.isExpanded(.team))
        #expect(OverviewSession.task("leaf", in: tasks)?.title == "Leaf")
        #expect(OverviewSession.task("deleted", in: tasks) == nil)
        session.expandedSections[.tasks] = false
        session.prepareForTaskReveal()
        #expect(session.navigationPath.isEmpty && session.isExpanded(.tasks))
        #expect(session.taskDisclosure["child"]?.expanded == false)
    }

    @Test func detachedWorkingHostNeverAnimatesAndVisibilityChangesReuseItsNativeGlyph() throws {
        let view = OverviewEllipsisView()
        view.frame = CGRect(x: 0, y: 0, width: 12, height: 9)
        view.configure(size: 9, scale: 3, color: .secondaryLabel, active: true)
        view.layoutIfNeeded()
        let imageView = try #require(view.subviews.first as? UIImageView)
        let image = try #require(imageView.image)
        #expect(view.pulse.segments.allSatisfy { $0.animation(forKey: "pulse") == nil && $0.opacity == 1 })
        view.configure(size: 9, scale: 3, color: .secondaryLabel, active: false)
        #expect(imageView.image === image)
        #expect(!view.isAccessibilityElement && view.accessibilityElementsHidden)
        view.stop()
        #expect(view.pulse.segments.allSatisfy { $0.animationKeys()?.isEmpty != false && $0.opacity == 1 })
    }

    @Test func taskTimingMetadataKeepsItsTextWithoutAnOversizedEmptyRow() throws {
        let renderer = ImageRenderer(content:
            Button {} label: {
                OverviewTaskMetadata(timing: .init(elapsedMinutes: 86, checkInMinutes: 31), diff: nil)
            }
            .buttonStyle(.plain)
            .dynamicTypeSize(.large)
            .environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(width: 300, height: nil)
        renderer.scale = 1
        let image = try #require(renderer.uiImage)
        #expect(image.size.width > 100 && image.size.width <= 300)
        #expect(image.size.height > 10 && image.size.height < 50)
    }

    @Test(arguments: [ColorScheme.light, .dark], DynamicTypeSize.allCases)
    func waitingCueStaysCenteredOnTheFirstLineWhileTheReasonWraps(
        scheme: ColorScheme, size: DynamicTypeSize
    ) throws {
        let renderer = ImageRenderer(content:
            OverviewAgentStatus(
                presence: .init(state: "waiting", text: "WAITING MMMM MMMM MMMM MMMM MMMM"),
                live: true)
                .frame(width: 180, alignment: .leading)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
                .dynamicTypeSize(size))
        renderer.scale = 3
        let image = try #require(renderer.uiImage?.cgImage)
        let pixels = try rgba(image)
        let background = scheme == .dark ? 0 : 255
        var cueRows = Set<Int>()
        var textRows = Set<Int>()
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                if red > green + 20, green > blue + 20 { cueRows.insert(y) }
                if abs(red - green) <= 4, abs(green - blue) <= 4, abs(red - background) > 24 {
                    textRows.insert(y)
                }
            }
        }
        let firstTextRow = try #require(textRows.min())
        var lastFirstLineRow = firstTextRow
        while textRows.contains(lastFirstLineRow + 1) { lastFirstLineRow += 1 }
        let firstCueRow = try #require(cueRows.min())
        let lastCueRow = try #require(cueRows.max())
        #expect(abs(CGFloat(firstCueRow + lastCueRow - firstTextRow - lastFirstLineRow) / 6) <= 1,
                "Cue \(firstCueRow)...\(lastCueRow), first line \(firstTextRow)...\(lastFirstLineRow)")
        #expect(try #require(textRows.max()) > lastFirstLineRow)
    }

    @Test(arguments: DynamicTypeSize.allCases)
    func teamRowsAreTwoPointsShorterOnlyAtOrdinaryTextSizes(
        size: DynamicTypeSize
    ) async throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"),
                                 sendJournal: nil)
        let state = ChannelState(
            revision: 1,
            channel: .init(id: "channel", name: "Team", model: .init(provider: "test", name: "test"),
                           updatedAt: "2026-10-26T00:00:00Z"),
            lead: .lead(id: "channel", profile: .init(name: "Agent", role: "Engineer",
                                                    avatar: .init(mark: "M4 12H20", color: "#123456"))))
        _ = try store.apply(.init(type: "snapshot", state: state))
        let session = OverviewSession(store: store)
        let host = UIHostingController(rootView:
            NavigationStack {
                OverviewList {
                    OverviewTeamSection(store: store, session: session)
                    OverviewTeamRow(agent: state.lead, store: store, session: session, isLead: true)
                }
                .navigationDestination(for: OverviewRoute.self) { _ in EmptyView() }
            }
            .environment(ChannelInteraction()).environment(ManagementPresenter())
            .environment(try artifactSession(artifacts: []))
            .environment(\.horizontalSizeClass, .compact)
            .dynamicTypeSize(size))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1400))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let list = try #require(nativeList(in: host.view))
        list.layoutIfNeeded()
        let tightened = try #require(list.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))).frame
        let addAgent = try #require(list.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))).frame
        let native = try #require(list.layoutAttributesForItem(at: IndexPath(item: 0, section: 1))).frame
        let reduction: CGFloat = size.isAccessibilitySize ? 0 : 2
        #expect(tightened.width == native.width && tightened.height >= 44)
        #expect(abs(native.height - tightened.height - reduction) < 0.01,
                "Tightened row \(tightened), native row \(native)")
        if size == .large {
            #expect(abs(addAgent.height - tightened.height) < 0.01,
                    "Add Agent \(addAgent), member \(tightened)")
        }
        let button = try #require(MobileAutomationTree(windows: [window]).elements.first {
            $0.identifier == "overview-add-agent"
        })
        #expect(button.traits.contains(.button) && button.frame.height >= 44)
        #expect(abs(button.frame.height - addAgent.height) < 0.01)
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith:
            UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size)))
        #expect(addAgent.height >= body.lineHeight + (size.isAccessibilitySize ? 30 : 28))
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility5])
    func teamCountdownKeepsTheDefaultRowHeightAndOneCurrentAccessibleAnnouncement(
        size: DynamicTypeSize
    ) async throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"),
                                 sendJournal: nil)
        let wake = Date.now.addingTimeInterval(480).ISO8601Format()
        var state = ChannelState(
            revision: 1,
            channel: .init(id: "channel", name: "Team", model: .init(provider: "test", name: "test"),
                           updatedAt: "2026-10-26T00:00:00Z"),
            lead: .lead(id: "channel", profile: .init(name: "Agent", role: "Engineer",
                                                    avatar: .init(mark: "M4 12H20", color: "#123456"))),
            members: [.init(id: "member", name: "Agent", role: "Engineer")])
        let agentID = state.lead.id
        let reason = "WAITING MMMM MMMM MMMM MMMM MMMM"
        state.presence = [agentID: .init(state: "waiting", text: reason, wakeAt: wake),
                          "member": .init(state: "waiting", text: reason)]
        _ = try store.apply(.init(type: "snapshot", state: state))
        let session = OverviewSession(store: store)
        let interaction = ChannelInteraction()
        interaction.isInspectorPresented = true
        let host = UIHostingController(rootView:
            NavigationStack {
                OverviewList {
                    ForEach(store.roster) { agent in
                        OverviewTeamRow(agent: agent, store: store, session: session,
                                        isLead: agent.id == agentID)
                    }
                }
                .navigationDestination(for: OverviewRoute.self) { _ in EmptyView() }
            }
            .environment(interaction).environment(ManagementPresenter())
            .environment(try artifactSession(artifacts: []))
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.locale, Locale(identifier: "en_US"))
            .dynamicTypeSize(size))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1400))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        func settle(announcement: Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            repeat {
                host.view.layoutIfNeeded()
                let value = MobileAutomationTree(windows: [window]).elements.first {
                    $0.identifier == "overview-agent-\(agentID)"
                }?.value ?? ""
                if value.hasPrefix("checks again in ") == announcement { return }
                try await Task.sleep(for: .milliseconds(5))
            } while ContinuousClock.now < deadline
            Issue.record("Team row did not settle with countdown announcement \(announcement)")
        }
        try await settle(announcement: true)
        let list = try #require(nativeList(in: host.view))
        let withCountdown = try #require(list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
        let withoutCountdown = try #require(list.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))).frame
        if size.isAccessibilitySize {
            #expect(withCountdown.height > withoutCountdown.height && withoutCountdown.height > 44)
        } else {
            #expect(abs(withCountdown.height - withoutCountdown.height) < 0.5)
        }
        let tree = MobileAutomationTree(windows: [window])
        let row = try #require(tree.elements.first { $0.identifier == "overview-agent-\(agentID)" })
        #expect(row.label == "Agent, \(reason)")
        #expect(tree.elements.filter {
            $0.label.contains("checks again in ") || $0.value.contains("checks again in ")
        }.count == 1)

        interaction.isInspectorPresented = false
        try await settle(announcement: false)
        interaction.isInspectorPresented = true
        try await settle(announcement: true)
        state.revision += 1
        state.presence[agentID] = .init(state: "working", text: "Compiling", wakeAt: wake)
        _ = try store.apply(.init(type: "snapshot", state: state))
        try await settle(announcement: false)
        #expect(MobileAutomationTree(windows: [window]).elements.first {
            $0.identifier == "overview-agent-\(agentID)"
        }?.label == "Agent, Working, Compiling")
    }

    @Test(arguments: [false, true])
    func plainOverviewSeparatesSectionsWithStrongerHeadingsAndDeliberateGaps(expanded: Bool) async throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let session = OverviewSession(store: store)
        session.expandedSections[.team] = expanded
        session.expandedSections[.tasks] = expanded
        let host = UIHostingController(rootView:
            OverviewList {
                OverviewSectionRows(summary: .team(1), section: .team, session: session, isFirstSection: true) {
                    Text("Ada").frame(height: 44).listRowInsets(.vertical, 0)
                }
                OverviewSectionRows(summary: .tasks(channelTasksProgress([
                    ChannelTask(id: "task", title: "Build", status: "pending")
                ])),
                                    section: .tasks, session: session) {
                    Text("Build").frame(height: 44).listRowInsets(.vertical, 0)
                }
            }
            .dynamicTypeSize(.large)
            .environment(\.horizontalSizeClass, .compact))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let list = try #require(nativeList(in: host.view))
        list.layoutIfNeeded()
        let headings = try (0..<2).map { section in
            try #require(list.layoutAttributesForItem(at: IndexPath(item: 0, section: section))).frame
        }
        let first = headings[0]
        let top = list.convert(first, to: host.view).minY - host.view.safeAreaInsets.top
        #expect(abs(top - 12) < 0.5,
                "Top \(top), inset \(list.adjustedContentInset), offset \(list.contentOffset), headings \(headings)")
        #expect(abs(first.height - (expanded ? 48 : 44)) < 0.5)
        if expanded {
            let body = try #require(list.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))).frame
            #expect(abs(body.height - 44) < 0.5)
            #expect(abs(body.minY - first.maxY) < 0.5)
            #expect(abs(headings[1].minY - body.maxY - 24) < 0.5)
        } else {
            #expect(list.numberOfItems(inSection: 0) == 1)
            #expect(list.numberOfItems(inSection: 1) == 1)
            #expect(abs(headings[1].minY - first.maxY - 24) < 0.5)
        }
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility5])
    func overviewActionRowShowsOnlyTwoIconsNotVisibleActionTitles(size: DynamicTypeSize) throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let renderer = ImageRenderer(content:
            OverviewRootActions(store: store)
                .environment(ChannelInteraction()).environment(ManagementPresenter())
                .environment(ChannelFollowController())
                .dynamicTypeSize(size))
        let image = try #require(renderer.uiImage)
        #expect(image.size == CGSize(width: 88, height: 44))
    }

    @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility5])
    func loadedOpeningAlignsItsFirstLineAndUsesTheSameGapAsEverySection(
        teamExpanded: Bool, size: DynamicTypeSize
    ) async throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"),
                                 sendJournal: nil)
        _ = try store.apply(.init(type: "snapshot", state: .init(
            revision: 1,
            channel: .init(id: "channel", name: "Workshop", purpose: "Build.", directory: "/Workshop",
                           model: .init(provider: "test", name: "test"),
                           preview: .init(kind: "url", url: "https://example.com"),
                           updatedAt: "2026-10-26T00:00:00Z"),
            lead: .lead(id: "channel", profile: .init(name: "Lead", role: "Coordinator",
                                                    avatar: .init(mark: "M4 12H20", color: "#123456")))
        )))
        let session = OverviewSession(store: store)
        session.expandedSections[.team] = teamExpanded
        let host = UIHostingController(rootView:
            OverviewView(store: store, session: session, placement: .sheet)
                .environment(OverviewPresentation()).environment(ChannelInteraction())
                .environment(ChannelFollowController())
                .environment(ManagementPresenter()).environment(try artifactSession(artifacts: []))
                .environment(\.horizontalSizeClass, .compact).dynamicTypeSize(size))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 1600))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let tree = MobileAutomationTree(windows: [window])
        let purpose = try #require(tree.elements.first { $0.label == "Build." })
        let close = try #require(tree.elements.first { $0.label == "Close Overview" })
        let menu = try #require(tree.elements.first { $0.identifier == "overview-channel-actions" })
        #expect(abs(menu.frame.width - 44) < 0.5 && abs(close.frame.width - 44) < 0.5)
        #expect(abs(close.frame.maxX - menu.frame.minX - 88) < 0.5)
        #expect(menu.frame.height >= 44 && close.frame.height >= 44)
        #expect(abs(menu.frame.midY - close.frame.midY) < 0.5)
        #expect(abs(purpose.frame.midY - close.frame.midY) <= 1,
                "Purpose \(purpose.frame), Close \(close.frame)")
        let openingInset = close.frame.minY - window.safeAreaInsets.top
        if size.isAccessibilitySize {
            #expect(openingInset >= 12 && openingInset <= 24)
        } else {
            #expect(abs(openingInset - 12) < 0.5,
                    "Loaded Close \(close.frame), safe area \(window.safeAreaInsets)")
        }
        let list = try #require(nativeList(in: host.view))
        let about = try #require(list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
        let team = try #require(list.layoutAttributesForItem(at: IndexPath(item: 0, section: 1))).frame
        let lastTeam = try #require(list.layoutAttributesForItem(
            at: IndexPath(item: list.numberOfItems(inSection: 1) - 1, section: 1))).frame
        let tasks = try #require(list.layoutAttributesForItem(at: IndexPath(item: 0, section: 2))).frame
        #expect(abs(team.minY - about.maxY - 24) < 0.5,
                "About \(about), Team \(team), last Team \(lastTeam), Tasks \(tasks)")
        #expect(abs(tasks.minY - lastTeam.maxY - (team.minY - about.maxY)) < 0.5,
                "About-to-Team \(team.minY - about.maxY), Team-to-Tasks \(tasks.minY - lastTeam.maxY)")
    }

    @Test(arguments: ["screen", "url"], [ColorScheme.light, .dark])
    func openingShowsACopyableFolderNameAndOnlyURLPreviewsShowAnAddress(
        kind: String, scheme: ColorScheme
    ) async throws {
        let directory = "/srv/work/toy-box-desktop/"
        let screenID = "window:12345:67890:123456789"
        let address = "https://example.com/preview"
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"),
                                 sendJournal: nil)
        _ = try store.apply(.init(type: "snapshot", state: .init(
            revision: 1,
            channel: .init(id: "channel", name: "Workshop", purpose: "Build.", directory: directory,
                           model: .init(provider: "test", name: "test"),
                           preview: kind == "screen" ? .init(kind: kind, screenId: screenID)
                               : .init(kind: kind, url: address),
                           updatedAt: "2026-10-26T00:00:00Z"),
            lead: .lead(id: "channel", profile: .init(name: "Lead", role: "Coordinator",
                                                    avatar: .init(mark: "M4 12H20", color: "#123456")))
        )))
        let host = UIHostingController(rootView:
            OverviewView(store: store, session: OverviewSession(store: store), placement: .sheet)
                .environment(OverviewPresentation()).environment(ChannelInteraction())
                .environment(ChannelFollowController())
                .environment(ManagementPresenter()).environment(try artifactSession(artifacts: []))
                .environment(\.horizontalSizeClass, .compact)
                .environment(\.colorScheme, scheme)
                .dynamicTypeSize(.large))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 1200))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let tree = MobileAutomationTree(windows: [window])
        let folder = try #require(tree.elements.first { $0.identifier == "overview-folder" })
        #expect(folder.label == "Folder, toy-box-desktop" && folder.traits.contains(.button))
        #expect(folder.frame.height >= 44)
        for removed in [directory, screenID, "Folder on Mac", "Copy Folder Path"] {
            #expect(!tree.elements.contains { $0.label.contains(removed) || $0.value.contains(removed) })
        }
        #expect(tree.elements.contains { $0.label == "Screen Preview" } == (kind == "screen"))
        #expect(tree.elements.contains { $0.label.contains(address) } == (kind == "url"))
    }

    @Test(arguments: [UserInterfaceSizeClass.compact, .regular])
    func overviewRootHasNoNavigationBarButNestedScreensKeepTheirs(sizeClass: UserInterfaceSizeClass) async throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let session = OverviewSession(store: store)
        let host = UIHostingController(rootView:
            OverviewView(store: store, session: session, placement: .sheet)
                .environment(OverviewPresentation())
                .environment(ChannelInteraction())
                .environment(ManagementPresenter())
                .environment(ChannelFollowController())
                .environment(\.horizontalSizeClass, sizeClass))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let navigation = try #require(nativeNavigation(in: host))
        #expect(navigation.isNavigationBarHidden)
        let close = try #require(MobileAutomationTree(windows: [window]).elements.first {
            $0.label == "Close Overview" && $0.traits.contains(.button)
        })
        #expect(close.frame.width >= 44 && close.frame.height >= 44)
        #expect(abs(close.frame.minY - window.safeAreaInsets.top - 12) < 0.5,
                "Close \(close.frame), window safe area \(window.safeAreaInsets), host safe area \(host.view.safeAreaInsets), navigation \(navigation.view.frame), bar \(navigation.navigationBar.frame)")
        session.navigationPath = [.agent("agent")]
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while navigation.isNavigationBarHidden || navigation.topViewController?.navigationItem.title != "About Agent",
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            host.view.layoutIfNeeded()
        }
        #expect(!navigation.isNavigationBarHidden)
        #expect(navigation.topViewController?.navigationItem.title == "About Agent")
    }

    @Test func listRowsKeepTheSeparatorBetweenRowsButNotBelowTheLastRow() async throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let session = OverviewSession(store: store)
        let host = UIHostingController(rootView:
            OverviewList {
                OverviewSectionRows(summary: .artifacts(2), section: .artifacts, session: session,
                                    isFirstSection: true) {
                    Text("First").listRowSeparatorTint(.red)
                        .modifier(OverviewListRowBoundary(isLast: false))
                    Text("Last").listRowSeparatorTint(.red)
                        .modifier(OverviewListRowBoundary(isLast: true))
                }
            }
            .environment(\.colorScheme, .light))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let list = try #require(nativeList(in: host.view))
        try expectSeparators(in: list, window: window, visible: [IndexPath(item: 1, section: 0)],
                             hidden: [IndexPath(item: 2, section: 0)])
    }

    @Test(arguments: [false, true])
    func finalRoutineKeepsItsInteriorSeparatorsButNotTheLastOne(expanded: Bool) async throws {
        let suite = "mobile-overview-routines-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:], defaults: defaults)
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let state = OverviewRoutineState()
        state.expanded = expanded
        let host = UIHostingController(rootView:
            OverviewList {
                OverviewRoutineRow(
                    routine: .init(id: "routine", title: "Daily review", schedule: "0 9 * * *",
                                   prompt: "Review the workshop."),
                    store: store, state: state, isLast: true)
                    .listRowSeparatorTint(.red)
            }
            .environment(model).environment(ManagementPresenter())
            .environment(\.colorScheme, .light))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let list = try #require(nativeList(in: host.view))
        let count = list.numberOfItems(inSection: 0)
        try #require(count == (expanded ? 6 : 1))
        try expectSeparators(
            in: list, window: window,
            visible: (0..<max(0, count - 1)).map { IndexPath(item: $0, section: 0) },
            hidden: [IndexPath(item: count - 1, section: 0)])
    }

    @Test(arguments: ["plan.md", "workshop.html", "shapes.svg", "reference.png", "unknown.bin"])
    func artifactSymbolsKeepTheCurrentDocumentIconsBounds(path: String) throws {
        let renderer = ImageRenderer(content: OverviewArtifactSymbol(artifact: artifact(path), size: 22))
        let image = try #require(renderer.uiImage)
        #expect(image.size == CGSize(width: 22, height: 22))
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility5],
          ["Design", "Design notes for the workshop and the next release"])
    func artifactRowsKeepSixPointInsetsAndGrowWithTitlesAndTextSize(
        size: DynamicTypeSize, title: String
    ) async throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let session = OverviewSession(store: store)
        let viewer = try artifactSession(artifacts: [])
        let value = ChannelArtifact(file: .init(kind: "machine", path: "plan.md"), title: title)
        let host = UIHostingController(rootView:
            OverviewList {
                OverviewTeamRow(agent: .init(id: "agent", name: "Design"), store: store,
                                session: session, isLead: true)
                OverviewArtifactRow(
                    artifact: value,
                    share: nil, api: store.api, channelID: store.id)
                    .listRowInsets(.vertical, 6)
            }
            .environment(ManagementPresenter()).environment(ChannelInteraction()).environment(viewer)
            .environment(\.horizontalSizeClass, .compact).dynamicTypeSize(size))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let list = try #require(nativeList(in: host.view))
        let team = try #require(list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
        let artifact = try #require(list.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))).frame
        #expect(artifact.height >= 44)
        let label = ImageRenderer(content: OverviewArtifactLabel(artifact: value, share: nil).dynamicTypeSize(size))
        label.proposedSize = ProposedViewSize(width: artifact.width - 32, height: nil)
        let labelImage = try #require(label.uiImage)
        #expect(abs(artifact.height - labelImage.size.height - 12) <= 1)
        if size == .large, title == "Design" {
            #expect(abs(artifact.height - 56) <= 1)
            #expect(artifact.height < 64)
        } else if size.isAccessibilitySize {
            #expect(team.height > 64 && artifact.height > 64)
        }
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility5])
    func artifactTitleKeepsFourPointsBeforeItsModifiedTime(size: DynamicTypeSize) async throws {
        let host = UIHostingController(rootView:
            OverviewArtifactLabel(artifact: artifact("plan.md"), share: nil)
                .frame(width: 350).dynamicTypeSize(size))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let tree = MobileAutomationTree(windows: [window])
        let title = try #require(tree.elements.first { $0.label == "plan.md" })
        let modified = try #require(tree.elements.first { $0.label == "Share date unavailable" })
        #expect(abs(modified.frame.minY - title.frame.maxY - 4) < 0.5,
                "Title \(title.frame), modified \(modified.frame)")
    }

    @Test func taskRevealScrollsToTheNativeSectionInsteadOfOnlyExpandingIt() async throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let session = OverviewSession(store: store)
        session.expandedSections[.tasks] = false
        session.scrollPosition.scrollTo(point: CGPoint(x: 0, y: 244))
        session.scrollOffset = 244
        session.prepareForPresentation()
        let host = UIHostingController(rootView:
            ScrollViewReader { proxy in
                OverviewList {
                    OverviewSectionRows(summary: .team(20), section: .team, session: session,
                                        isFirstSection: true) {
                        ForEach(0..<20, id: \.self) { index in
                            Text("Agent \(index)").frame(height: 44).listRowInsets(.vertical, 0)
                        }
                    }
                    OverviewSectionRows(summary: .tasks(channelTasksProgress([
                        ChannelTask(id: "task", title: "Build", status: "pending")
                    ])), section: .tasks, session: session) {
                        Text("Build").frame(height: 44).listRowInsets(.vertical, 0)
                    }
                    OverviewSectionRows(summary: .artifacts(20), section: .artifacts, session: session) {
                        ForEach(0..<20, id: \.self) { index in
                            Text("Artifact \(index)").frame(height: 44).listRowInsets(.vertical, 0)
                        }
                    }
                }
                .scrollPosition(Binding(
                    get: { session.scrollPosition },
                    set: { session.scrollPosition = $0 }))
                .onAppear { session.prepareForTaskReveal() }
                .task {
                    await Task.yield()
                    session.prepareForTaskReveal()
                    proxy.scrollTo("overview-tasks", anchor: .top)
                }
            }
            .dynamicTypeSize(.large)
            .environment(\.horizontalSizeClass, .compact))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let list = try #require(nativeList(in: host.view))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while list.contentOffset.y < 600, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            host.view.layoutIfNeeded()
        }
        #expect(session.isExpanded(.tasks))
        #expect(list.contentOffset.y > 600)
        let target = try #require(list.layoutAttributesForItem(at: IndexPath(item: 0, section: 1))).frame
        let top = list.convert(target, to: host.view).minY - host.view.safeAreaInsets.top
        #expect(abs(top) < 0.5, "Tasks must land at the viewport top, not just exist below it: \(top)")
    }

    @Test(arguments: [ColorScheme.light, .dark], [true, false])
    func artifactActionUsesOnlyNormalInsetsAndKeepsItsEnabledInkUnderLinkTint(
        scheme: ColorScheme, enabled: Bool
    ) throws {
        let renderer = ImageRenderer(content:
            Button {} label: {
                OverviewTaskArtifactLabel(title: enabled ? "Plan" : "Artifact unavailable")
            }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .foregroundStyle(Color.blue)
            .tint(.blue)
            .background(scheme == .dark ? Color.black : Color.white)
            .dynamicTypeSize(.large)
            .environment(\.colorScheme, scheme))
        renderer.proposedSize = ProposedViewSize(width: 220, height: nil)
        renderer.scale = 1
        let image = try #require(renderer.uiImage)
        let cgImage = try #require(image.cgImage)
        #expect(image.size.height < 44)
        let pixels = try rgba(cgImage)
        var inkRows: [Int] = []
        var tintedPixels = 0
        let background = scheme == .dark ? 0 : 255
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let color = (enabled ? UIColor.label : .tertiaryLabel).resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        let expected = [red, green, blue].map {
            Int(($0 * alpha * 255 + CGFloat(background) * (1 - alpha)).rounded())
        }
        let inkThreshold = abs(expected[0] - background) / 2
        var strongestOffset = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if abs(Int(pixels[offset]) - Int(pixels[offset + 2])) > 1 { tintedPixels += 1 }
            let distance = abs(Int(pixels[offset]) - background)
            if distance > inkThreshold { inkRows.append(offset / (cgImage.width * 4)) }
            if distance > abs(Int(pixels[strongestOffset]) - background) { strongestOffset = offset }
        }
        if enabled { #expect(tintedPixels == 0) }
        for component in 0..<3 {
            #expect(abs(Int(pixels[strongestOffset + component]) - expected[component]) <= 2)
        }
        let first = try #require(inkRows.min())
        let last = try #require(inkRows.max())
        let bottom = cgImage.height - 1 - last
        #expect(first >= Int(ChannelOverviewFactsLayout.titleGap))
        #expect(bottom >= 11)
        #expect(abs(CGFloat(bottom - first) - (11 - ChannelOverviewFactsLayout.titleGap)) <= 2)
    }

    @Test func linkedArtifactAddsNoMoreRowHeightThanAnOrdinaryMetadataLine() throws {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        let session = OverviewSession(store: store)
        let viewer = try artifactSession(artifacts: [])
        let layout = OverviewTaskReadingLayout(
            contentWidth: 220, statusWidth: 16, titleGap: 6, ownerWidth: 20,
            scaledReadingWidth: 192, accessibility: false, rootHasOwner: false)
        func rendered(_ task: ChannelTask) throws -> UIImage {
            let renderer = ImageRenderer(content:
                OverviewTaskNode(task: task, store: store, session: session, depth: 0, layout: layout)
                    .environment(viewer)
                    .dynamicTypeSize(.large))
            renderer.proposedSize = ProposedViewSize(width: 220, height: nil)
            renderer.scale = 3
            return try #require(renderer.uiImage)
        }
        let title = "Design: every screen agreed with Mac parity"
        let linked = try rendered(.init(id: "linked", title: title, status: "done", artifactId: "artifact"))
        let metadata = try rendered(.init(id: "metadata", title: title, status: "done",
                                         diff: .init(added: 1, removed: 1)))
        #expect(abs(linked.size.height - metadata.size.height) <= 1)
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility5])
    func anArtifactActionGrowsToFitItsWrappingLabel(size: DynamicTypeSize) throws {
        let renderer = ImageRenderer(content:
            Button {} label: {
                OverviewTaskArtifactLabel(title: "The design plan and its supporting decisions")
            }
            .buttonStyle(.borderless)
            .dynamicTypeSize(size))
        renderer.proposedSize = ProposedViewSize(width: 180, height: nil)
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        #expect(image.size.height > 44)
    }

    @Test func cancellingRemovalRestoresTheEditorAndOldSessionsCannotCompleteANewFlow() throws {
        try withModel { app in
            let catalog = try #require(app.catalog)
            let sessions = ManagementSessions()
            let presenter = ManagementPresenter()
            let editing = ManagementFlow.editMember(channelId: "channel", agentId: "agent")
            presenter.present(editing)
            let editor = sessions.session(for: editing, catalog: catalog)
            editor.name = "Unsaved name"
            editor.role = "Unsaved role"
            let removing = ManagementFlow.removeMember(channelId: "channel", agentId: "agent")
            presenter.present(removing)
            let confirmation = sessions.session(for: removing, catalog: catalog)
            sessions.cancel(confirmation, presenter: presenter)
            #expect(presenter.flow == editing)
            #expect(sessions.session(for: editing, catalog: catalog) === editor)
            #expect(editor.name == "Unsaved name" && editor.role == "Unsaved role")
            sessions.reset()
            let replacement = sessions.session(for: editing, catalog: catalog)
            #expect(replacement !== editor)
            #expect(!sessions.isCurrent(editor, app: app, presenter: presenter))
            #expect(sessions.isCurrent(replacement, app: app, presenter: presenter))
            try app.configure(serverURL: "https://other.example", persist: false)
            try app.configure(serverURL: "https://fixture.example", persist: false)
            #expect(!sessions.isCurrent(replacement, app: app, presenter: presenter))
        }
    }

    @Test func artifactFactoryRetainsTheStoreSessionAndClosesAReplacedStore() throws {
        let suite = "mobile-overview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:], defaults: defaults)
        let api = try #require(model.api)
        let store = ChannelStore(id: "channel", api: api)
        let session = model.artifactSession(for: store)
        session.open(ChannelArtifact(file: .init(kind: "machine", path: "document.md"), title: "Document"))
        #expect(model.artifactSession(for: store) === session)
        #expect(session.isPresented)
        let replacement = model.artifactSession(for: ChannelStore(id: store.id, api: api))
        #expect(replacement !== session)
        #expect(!session.isPresented)
        #expect(replacement.channelID == store.id)
        #expect(replacement.server == api.baseURL)
    }

    @Test func changingSelectionClosesTheVisitAndChangingServerDiscardsItsSession() throws {
        let suite = "mobile-overview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:], defaults: defaults)
        let artifact = ChannelArtifact(file: .init(kind: "machine", path: "document.md"), title: "Document")
        model.selectedChannelID = "first"
        let first = model.artifactSession(for: try #require(model.selectedStore))
        first.open(artifact)
        model.selectedChannelID = "second"
        #expect(!first.isPresented)
        let second = model.artifactSession(for: try #require(model.selectedStore))
        second.open(artifact)
        try model.configure(serverURL: "https://replacement.example", persist: false)
        #expect(!second.isPresented)
        #expect(model.selectedStore == nil)
        model.selectedChannelID = "second"
        let replacement = model.artifactSession(for: try #require(model.selectedStore))
        #expect(replacement !== second)
        #expect(replacement.server?.host == "replacement.example")
    }

    @Test func artifactImagesFitIntrinsicPointsWithoutUpscalingAndResetZoomForAnotherFile() {
        #expect(ArtifactImageScrollView.fitScale(image: CGSize(width: 64, height: 32),
                                                viewport: CGSize(width: 320, height: 600)) == 1)
        #expect(ArtifactImageScrollView.fitScale(image: CGSize(width: 1600, height: 800),
                                                viewport: CGSize(width: 320, height: 600)) == 0.2)
        let view = ArtifactImageScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        let first = URL(fileURLWithPath: "/fixture/first.png")
        view.configure(image: UIImage(), size: CGSize(width: 1600, height: 800), file: first, title: "First")
        #expect(view.minimumZoomScale == 0.2)
        #expect(abs(view.zoomScale - 0.2) < 0.001)
        view.actualSize()
        #expect(view.zoomScale == 1)
        view.configure(image: UIImage(), size: CGSize(width: 1600, height: 800),
                       file: URL(fileURLWithPath: "/fixture/second.png"), title: "Second")
        #expect(abs(view.zoomScale - 0.2) < 0.001)
        #expect(view.imageView.accessibilityLabel == "Second")
        view.stop()
        #expect(view.file == nil && view.imageView.image == nil)
    }

    @Test(arguments: [false, true])
    func nativeArtifactOriginalPreparationCannotPublishIntoAnotherSelectionOrServer(changingServer: Bool) async throws {
        let downloads = NativeArtifactOriginalDownloads()
        let first = artifact("first.dat")
        let second = artifact("second.dat")
        let session = try artifactSession(artifacts: [first, second])
        defer { session.close() }
        session.open(first)
        let reading = ArtifactReaderState(download: { _, _ in await downloads.file() })
        reading.prepareOriginal(session: session, sharing: true)
        let pending = try #require(reading.originalTask)
        try await waitForOriginal(downloads)
        if changingServer {
            session.configure(api: try ChannelAPI(serverURL: "https://replacement.example"),
                              channelID: "channel", artifacts: [first, second])
            session.open(first)
        } else { session.select(second.id) }
        await downloads.release(URL(fileURLWithPath: "/fixture/first.dat"))
        await pending.value
        #expect(reading.sharing == nil && reading.preview == nil)
        #expect(!reading.isPreparingOriginal)
        #expect(session.artifact?.id == (changingServer ? first.id : second.id))
        #expect(session.actionError == nil)
    }

    @Test func nativeArtifactOriginalCancellationCannotReopenASheetOrClearANewerAction() async throws {
        let downloads = NativeArtifactOriginalDownloads()
        let file = artifact("first.dat")
        let session = try artifactSession(artifacts: [file])
        defer { session.close() }
        session.open(file)
        let reading = ArtifactReaderState(download: { _, _ in await downloads.file() })
        reading.prepareOriginal(session: session, sharing: true)
        let pending = try #require(reading.originalTask)
        try await waitForOriginal(downloads)
        reading.cancelOriginal()
        #expect(!reading.isPreparingOriginal)
        reading.prepareOriginal(session: session, sharing: true)
        let newer = try #require(reading.originalTask)
        try await waitForOriginal(downloads, count: 2)
        await downloads.release(URL(fileURLWithPath: "/fixture/first.dat"))
        await pending.value
        #expect(reading.sharing == nil && reading.preview == nil)
        #expect(reading.isPreparingOriginal && reading.originalTask != nil)
        let current = URL(fileURLWithPath: "/fixture/current.dat")
        await downloads.release(current, request: 2)
        await newer.value
        #expect(reading.sharing?.file == current)
        #expect(!reading.isPreparingOriginal && reading.originalTask == nil)
        #expect(session.actionError == nil)
    }

    @Test func nativeArtifactOriginalFailureIsAnActionErrorWithoutClosingTheArtifact() async throws {
        let file = artifact("first.dat")
        let session = try artifactSession(artifacts: [file])
        defer { session.close() }
        session.open(file)
        let reading = ArtifactReaderState(download: { _, _ in throw URLError(.timedOut) })
        reading.prepareOriginal(session: session, sharing: true)
        await reading.originalTask?.value
        #expect(session.actionError == URLError(.timedOut).localizedDescription)
        #expect(session.artifact?.id == file.id)
        #expect(!reading.isPreparingOriginal)
    }

    @Test func artifactNativeReadingStateSurvivesPresentationCoverageButEndsWithTheVisit() {
        let reading = ArtifactReaderState()
        reading.markdownOffsets["artifact"] = 480
        reading.sharing = ArtifactShare(file: URL(fileURLWithPath: "/fixture/document.md"))
        reading.stopPendingOriginal()
        #expect(reading.markdownOffsets["artifact"] == 480)
        #expect(reading.sharing != nil)
        reading.reset()
        #expect(reading.markdownOffsets.isEmpty)
        #expect(reading.sharing == nil && reading.preview == nil)
    }

    @Test func artifactFitCallbacksDistinguishZoomFromFitAndDoNotPublishAnObsoletePage() async {
        let view = ArtifactImageScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        var fitted: [Bool] = []
        view.onFitChanged = { fitted.append($0) }
        view.configure(image: UIImage(), size: CGSize(width: 1600, height: 800),
                       file: URL(fileURLWithPath: "/fixture/first.png"), title: "First")
        await view.fitPublication?.value
        #expect(fitted == [true] && view.isAtFitScale)
        view.actualSize()
        await view.fitPublication?.value
        #expect(fitted == [true, false] && !view.isAtFitScale)
        view.fit()
        view.actualSize()
        await view.fitPublication?.value
        #expect(fitted == [true, false, false])
        view.fit()
        view.stop()
        await view.fitPublication?.value
        #expect(fitted == [true, false, false])
    }

    private func nativeList(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        return view.subviews.lazy.compactMap { nativeList(in: $0) }.first
    }

    private func nativeNavigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { nativeNavigation(in: $0) }.first
    }

    private func expectSeparators(in list: UICollectionView, window: UIWindow,
                                  visible: [IndexPath], hidden: [IndexPath]) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = try #require(UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }.cgImage)
        let pixels = try rgba(image)
        for (path, shouldBeVisible) in visible.map({ ($0, true) }) + hidden.map({ ($0, false) }) {
            let frame = try #require(list.layoutAttributesForItem(at: path)).frame
            let bottom = list.convert(frame, to: window).maxY
            var count = 0
            for y in 0..<image.height where abs(CGFloat(y) / 3 - bottom) <= 1 {
                for x in 0..<image.width {
                    let offset = (y * image.width + x) * 4
                    if pixels[offset] > 180,
                       Int(pixels[offset]) > Int(pixels[offset + 1]) + 80,
                       Int(pixels[offset]) > Int(pixels[offset + 2]) + 80 { count += 1 }
                }
            }
            #expect(shouldBeVisible ? count > 100 : count == 0,
                    "Row \(path): found \(count) separator pixels at \(bottom), expected visible: \(shouldBeVisible)")
        }
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return pixels
    }

    private func artifact(_ path: String) -> ChannelArtifact {
        ChannelArtifact(file: .init(kind: "machine", path: path), title: path, url: "/api/serve/test/\(path)")
    }

    private func artifactSession(artifacts: [ChannelArtifact]) throws -> ChannelArtifactSession {
        let session = ChannelArtifactSession(decodeImage: { _, _, _ in throw ChannelAttachmentError.invalidImage },
                                             download: { _, _ in throw URLError(.notConnectedToInternet) })
        session.configure(api: try ChannelAPI(serverURL: "https://fixture.example"),
                          channelID: "channel", artifacts: artifacts)
        return session
    }

    private func waitForOriginal(_ downloads: NativeArtifactOriginalDownloads, count: Int = 1) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await downloads.requests < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await downloads.requests == count)
    }

    private func withModel(_ body: (AppModel) throws -> Void) throws {
        let suite = "mobile-overview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppModel(arguments: ["--server", "https://fixture.example"], environment: [:], defaults: defaults))
    }

    private actor NativeArtifactOriginalDownloads {
        private(set) var requests = 0
        private var pending: [Int: CheckedContinuation<URL, Never>] = [:]

        func file() async -> URL {
            requests += 1
            let request = requests
            return await withCheckedContinuation { pending[request] = $0 }
        }

        func release(_ file: URL, request: Int = 1) {
            pending.removeValue(forKey: request)?.resume(returning: file)
        }
    }
}

@Suite("Mobile Following", .timeLimit(.minutes(1)))
@MainActor
struct ChannelFollowTests {
    @Test func aFollowRegistersOnceAndStopRemainsAvailableOffline() async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        fixture.holdRegistration = true
        let start = Task { await fixture.controller.follow(fixture.store) }
        await fixture.wait { !fixture.pending.isEmpty }
        #expect(fixture.controller.state(for: fixture.store) == .starting)
        await fixture.controller.follow(fixture.store)
        #expect(fixture.pool.activities.count == 1)
        fixture.releaseRegistration()
        await start.value
        #expect(fixture.controller.state(for: fixture.store) == .following)
        #expect(fixture.requests.map(\.method) == ["PUT"])
        #expect(fixture.requests.first?.input?.startedAt == fixture.date)
        #expect(fixture.requests.first?.registrationID == fixture.registration.registrationID)
        #expect(fixture.acquired == 1)
        fixture.store.disconnect()
        #expect(fixture.controller.state(for: fixture.store) == .following)
        fixture.controller.stop(channelID: fixture.store.id)
        let activity = try #require(fixture.pool.activities.first)
        await fixture.wait { !activity.endings.isEmpty && fixture.completedUnregistrations == 1 }
        #expect(activity.endings.first?.state.ending == .stopped)
        #expect(activity.endings.first?.dismissAt == nil)
        #expect(fixture.controller.state(for: fixture.store) == .unavailable)
        #expect(fixture.requests.map(\.method) == ["PUT", "DELETE"])
        #expect(fixture.released == 1)
        #expect(!fixture.controller.startFailed)
    }

    @Test func acknowledgmentEnablesFollowEvenWhenNotificationAlertsAreOff() async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        fixture.defaults.set(false, forKey: "notificationsEnabled")
        fixture.configure(ready: false)
        #expect(fixture.controller.state(for: fixture.store) == .unavailable)
        await fixture.controller.follow(fixture.store)
        #expect(fixture.pool.activities.isEmpty)
        #expect(fixture.requests.isEmpty)
        #expect(fixture.acquired == 0)

        fixture.configure(ready: true)
        #expect(fixture.controller.state(for: fixture.store) == .available)
        await fixture.controller.follow(fixture.store)
        #expect(fixture.pool.activities.count == 1)
        #expect(fixture.requests.map(\.method) == ["PUT"])
        #expect(fixture.controller.state(for: fixture.store) == .following)
        #expect(!fixture.controller.startFailed)
    }

    @Test(arguments: [false, true])
    func restoredTokensWaitForTheExistingRegistrationsAcknowledgment(rotatesWhilePending: Bool) async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        await fixture.controller.follow(fixture.store)
        let activity = try #require(fixture.pool.activities.first)
        await fixture.wait { activity.tokenStreamsStarted == 1 }
        fixture.controller.shutdown()
        fixture.controller = fixture.makeController()
        fixture.configure(ready: false)
        await fixture.wait { activity.tokenStreamsStarted == 2 }
        #expect(fixture.requests.count == 1)
        #expect(fixture.controller.state(for: fixture.store) == .following)
        #expect(activity.endings.isEmpty)

        fixture.date.addTimeInterval(60)
        if rotatesWhilePending { activity.rotate(Data([2])) }
        await fixture.controller.registrationCreated(fixture.registration)
        #expect(fixture.requests.count == 1)
        fixture.configure(ready: true)
        await fixture.wait { fixture.requests.count == 2 }
        #expect(fixture.requests.last?.input?.token == (rotatesWhilePending ? "02" : "01"))
        #expect(fixture.requests.last?.input?.startedAt == fixture.originalDate)
        #expect(fixture.pool.activities.count == 1)
        #expect(activity.isActive)
        #expect(activity.endings.isEmpty)
        #expect(fixture.controller.state(for: fixture.store) == .following)
        #expect(!fixture.controller.startFailed)
    }

    @Test func bufferedTokensCannotReplaceTheLatestTokenAfterAHeldAcknowledgment() async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        await fixture.controller.follow(fixture.store)
        let activity = try #require(fixture.pool.activities.first)
        await fixture.wait { activity.tokenStreamsStarted == 1 }
        fixture.holdRegistration = true
        activity.rotate(Data([2]))
        await fixture.wait { fixture.pending.count == 1 }
        #expect(fixture.requests.last?.input?.token == "02")

        activity.rotate(Data([3]))
        activity.rotate(Data([4]))
        fixture.releaseRegistration()
        await fixture.wait { fixture.requests.count == 3 }
        #expect(fixture.requests.compactMap { $0.input?.token } == ["01", "02", "04"])
        #expect(fixture.requests.allSatisfy { $0.input?.startedAt == fixture.originalDate })
        #expect(fixture.pool.activities.count == 1)
        #expect(activity.endings.isEmpty)
        #expect(fixture.controller.state(for: fixture.store) == .following)
        #expect(!fixture.controller.startFailed)
    }

    @Test func aRecreatedRegistrationRestoresCurrentFollowsWithoutRestartingActivities() async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        await fixture.controller.follow(fixture.store)
        let second = fixture.catalog.channel(id: "second")
        _ = try second.apply(.init(type: "snapshot", state: .init(
            revision: 1,
            channel: .init(id: second.id, name: "Second", model: .init(provider: "test", name: "test"),
                           tasks: [.init(id: "work", title: "Work")], updatedAt: "2026-10-27T00:00:00Z"),
            lead: .init(id: second.id, name: "Lead")
        )))
        await fixture.controller.follow(second)
        let activity = try #require(fixture.pool.activities.first)
        activity.rotate(Data([2]))
        await fixture.wait { fixture.requests.count == 3 }
        let content = fixture.pool.activities.map(\.content)

        await fixture.controller.registrationCreated(.init(
            serverURL: fixture.registration.serverURL, registrationID: UUID().uuidString
        ))
        await fixture.controller.registrationCreated(.init(
            serverURL: "https://another-server.invalid", registrationID: fixture.registration.registrationID
        ))
        #expect(fixture.requests.count == 3)

        fixture.date.addTimeInterval(60)
        await fixture.controller.registrationCreated(fixture.registration)
        let restored = fixture.requests.suffix(2)
        #expect(fixture.requests.map(\.method) == Array(repeating: "PUT", count: 5))
        #expect(Set(restored.compactMap { $0.input?.token }) == ["01", "02"])
        #expect(restored.allSatisfy {
            $0.registrationID == fixture.registration.registrationID
                && $0.input?.startedAt == fixture.originalDate
        })
        #expect(fixture.pool.activities.count == 2)
        #expect(fixture.pool.activities.allSatisfy { $0.isActive && $0.endings.isEmpty })
        #expect(fixture.pool.activities.map(\.content) == content)
        #expect(fixture.controller.state(for: fixture.store) == .following)
        #expect(fixture.controller.state(for: second) == .following)
        #expect(fixture.acquired == 2)
        #expect(fixture.released == 0)
        #expect(!fixture.controller.startFailed)
    }

    @Test func onlyLiveUnfinishedRootTasksEnableFollow() throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        #expect(fixture.controller.state(for: fixture.store) == .available)
        try fixture.apply(tasks: [.init(id: "root", title: "Done", status: "done", children: [
            .init(id: "child", title: "Still pending")
        ])])
        #expect(fixture.controller.state(for: fixture.store) == .unavailable)
        try fixture.apply(tasks: [])
        #expect(fixture.controller.state(for: fixture.store) == .unavailable)
        try fixture.apply()
        fixture.store.disconnect()
        #expect(fixture.controller.state(for: fixture.store) == .unavailable)
    }

    @Test(arguments: [false, true])
    func aFailedStartTearsDownThePartialActivityWithoutRetrying(missingToken: Bool) async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        fixture.pool.missingToken = missingToken
        fixture.registrationStatus = 500
        await fixture.controller.follow(fixture.store)
        let activity = try #require(fixture.pool.activities.first)
        await fixture.wait { !activity.endings.isEmpty && fixture.completedUnregistrations == 1 }
        #expect(fixture.controller.startFailed)
        #expect(fixture.controller.state(for: fixture.store) == .available)
        #expect(activity.endings.first?.dismissAt == nil)
        #expect(fixture.requests.filter { $0.method == "PUT" }.count == (missingToken ? 0 : 1))
        #expect(fixture.defaults.dictionary(forKey: ChannelFollowController.startTimesKey)?.isEmpty == true)
    }

    @Test func rotationAndRelaunchKeepTheOriginalStartAndExpiry() async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        await fixture.controller.follow(fixture.store)
        let activity = try #require(fixture.pool.activities.first)
        fixture.date.addTimeInterval(60)
        activity.rotate(Data([2]))
        await fixture.wait { fixture.requests.count == 2 }
        #expect(fixture.requests[1].input?.token == "02")
        #expect(fixture.requests[1].input?.startedAt == fixture.originalDate)
        fixture.controller.shutdown()
        fixture.controller = fixture.makeController()
        fixture.configure()
        #expect(fixture.controller.state(for: fixture.store) == .following)
        await fixture.wait { fixture.requests.count == 3 }
        #expect(fixture.requests[2].input?.startedAt == fixture.originalDate)
        fixture.date = fixture.originalDate.addingTimeInterval(ChannelFollowController.maximumLifetime)
        fixture.configure(active: true)
        await fixture.wait { !activity.endings.isEmpty && fixture.completedUnregistrations == 1 }
        #expect(activity.endings.last?.state.ending == .expired)
        #expect(fixture.controller.state(for: fixture.store) == .available)
    }

    @Test(arguments: [false, true])
    func liveCompletionAndRemovedTasksEndWithoutRestarting(removed: Bool) async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        await fixture.controller.follow(fixture.store)
        let activity = try #require(fixture.pool.activities.first)
        fixture.configure(active: true)
        try fixture.apply(tasks: removed ? [] : [.init(id: "root", title: "Done", status: "done")])
        await fixture.wait { !activity.endings.isEmpty && fixture.completedUnregistrations == 1 }
        #expect(activity.endings.last?.state.ending == (removed ? .tasksRemoved : .completed))
        #expect(activity.endings.last?.dismissAt
                == fixture.date.addingTimeInterval(ChannelFollowController.retainedEndingInterval))
        try fixture.apply()
        #expect(fixture.controller.state(for: fixture.store) == .available)
        #expect(fixture.pool.activities.count == 1)
    }

    @Test(arguments: [false, true])
    func deletionAndServerChangeRemoveTheLocalActivity(changingServer: Bool) async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        await fixture.controller.follow(fixture.store)
        let activity = try #require(fixture.pool.activities.first)
        fixture.holdUnregistration = true
        if changingServer {
            fixture.controller.configure(registration: nil, isRegistrationReady: false, catalog: nil, isActive: false,
                                         acquire: { _ in }, release: { _ in })
        } else {
            fixture.configure(active: true)
            _ = try fixture.store.apply(.init(type: "deleted"))
        }
        await fixture.wait { !activity.endings.isEmpty && !fixture.pendingUnregistrations.isEmpty }
        #expect(fixture.completedUnregistrations == 0)
        #expect(activity.endings.last?.state.ending == (changingServer ? .serverChanged : .channelDeleted))
        #expect(activity.endings.last?.dismissAt == nil)
        #expect(fixture.released == 1)
        fixture.releaseUnregistration()
        await fixture.wait { fixture.completedUnregistrations == 1 }
        #expect(fixture.requests.map(\.method) == ["PUT", "DELETE"])
    }

    @Test func stoppingAnInflightRegistrationCannotDeleteTheNextFollow() async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        fixture.holdRegistration = true
        let oldStart = Task { await fixture.controller.follow(fixture.store) }
        await fixture.wait { fixture.pending.count == 1 }
        fixture.controller.stop(channelID: fixture.store.id)
        let nextStart = Task { await fixture.controller.follow(fixture.store) }
        await fixture.wait { fixture.pool.activities.count == 2 }
        fixture.releaseRegistration()
        await oldStart.value
        await nextStart.value
        #expect(fixture.requests.map(\.method) == ["PUT", "DELETE", "PUT"])
        #expect(fixture.controller.state(for: fixture.store) == .following)
        #expect(!fixture.controller.startFailed)
    }

    @Test func reconnectingTheSameServerKeepsTheActivityAndItsOriginalStart() async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        await fixture.controller.follow(fixture.store)
        let activity = try #require(fixture.pool.activities.first)
        let replacement = ChannelCatalogStore(api: fixture.catalog.api)
        fixture.controller.configure(
            registration: fixture.registration, isRegistrationReady: true, catalog: replacement, isActive: false,
            acquire: { _ in }, release: { _ in }
        )
        #expect(fixture.controller.state(for: replacement.channel(id: fixture.store.id)) == .following)
        #expect(activity.endings.isEmpty)
        #expect(fixture.defaults.dictionary(forKey: ChannelFollowController.startTimesKey)?[activity.id]
                as? Double == fixture.originalDate.timeIntervalSince1970)
    }

    @Test func switchingServersAlsoRemovesARetainedCompletionCard() async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        await fixture.controller.follow(fixture.store)
        let activity = try #require(fixture.pool.activities.first)
        fixture.configure(active: true)
        try fixture.apply(tasks: [.init(id: "root", title: "Done", status: "done")])
        await fixture.wait { activity.endings.count == 1 && fixture.completedUnregistrations == 1 }
        fixture.controller.configure(registration: nil, isRegistrationReady: false, catalog: nil, isActive: false,
                                     acquire: { _ in }, release: { _ in })
        await fixture.wait { activity.endings.count == 2 }
        #expect(activity.endings.last?.dismissAt == nil)
    }

    @Test func restoringWaitsForTheSavedRegistrationWithoutRemovingTheActivity() async throws {
        let fixture = try FollowFixture()
        defer { fixture.close() }
        await fixture.controller.follow(fixture.store)
        let activity = try #require(fixture.pool.activities.first)
        fixture.controller.shutdown()
        fixture.controller = fixture.makeController()
        fixture.controller.configure(registration: nil, isRegistrationReady: false, catalog: fixture.catalog, isActive: false,
                                     acquire: { _ in }, release: { _ in })
        #expect(activity.endings.isEmpty)
        fixture.configure()
        #expect(fixture.controller.state(for: fixture.store) == .following)
        #expect(activity.endings.isEmpty)
    }
}

@MainActor @Observable
private final class FollowFixture {
    struct Write {
        let method: String
        let registrationID: String
        let input: PushSubscription?
    }

    let suite = "follow-\(UUID().uuidString)"
    let originalDate = Date(timeIntervalSince1970: 1_000_000)
    let defaults: UserDefaults
    let catalog: ChannelCatalogStore
    let store: ChannelStore
    let registration: MobilePushRegistration
    let pool = FollowActivities()
    var controller: ChannelFollowController!
    var date: Date
    var requests: [Write] = []
    var pending: [CheckedContinuation<Void, Error>] = []
    var pendingUnregistrations: [CheckedContinuation<Void, Error>] = []
    var holdRegistration = false
    var holdUnregistration = false
    var completedUnregistrations = 0
    var registrationStatus = 204
    var acquired = 0
    var released = 0

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        date = originalDate
        let address = "https://\(suite).invalid"
        let api = try ChannelAPI(serverURL: address)
        catalog = ChannelCatalogStore(api: api)
        store = catalog.channel(id: "channel")
        registration = .init(serverURL: address, registrationID: UUID().uuidString)
        controller = makeController()
        configure()
        try apply()
    }

    func makeController() -> ChannelFollowController {
        ChannelFollowController(client: pool.client, defaults: defaults,
                                now: { [unowned self] in self.date },
                                registerActivity: { [unowned self] _, registrationID, input in
                                    try await self.register(input, registrationID: registrationID)
                                },
                                unregisterActivity: { [unowned self] _, registrationID in
                                    try await self.unregister(registrationID: registrationID)
                                })
    }

    func configure(active: Bool = false, ready: Bool = true) {
        controller.configure(
            registration: registration, isRegistrationReady: ready, catalog: catalog, isActive: active,
            acquire: { [weak self] _ in self?.acquired += 1 },
            release: { [weak self] _ in self?.released += 1 }
        )
    }

    func apply(tasks: [ChannelTask] = [.init(id: "root", title: "Work")]) throws {
        _ = try store.apply(.init(type: "snapshot", state: .init(
            revision: (store.state?.revision ?? 0) + 1,
            channel: .init(id: "channel", name: "Workshop", model: .init(provider: "test", name: "test"),
                           tasks: tasks, updatedAt: "2026-10-27T00:00:00Z"),
            lead: .init(id: "channel", name: "Lead")
        )))
    }

    func wait(_ predicate: @escaping @MainActor @Sendable () -> Bool) async {
        for await ready in Observations({ predicate() }) {
            if ready { return }
        }
    }

    func register(_ input: PushSubscription, registrationID: String) async throws {
        requests.append(Write(method: "PUT", registrationID: registrationID, input: input))
        if holdRegistration {
            try await withCheckedThrowingContinuation { pending.append($0) }
        }
        if registrationStatus != 204 {
            throw ChannelAPIError.http(status: registrationStatus, message: "Registration failed")
        }
    }

    func releaseRegistration() {
        holdRegistration = false
        let requests = pending
        pending = []
        for request in requests { request.resume() }
    }

    func unregister(registrationID: String) async throws {
        requests.append(Write(method: "DELETE", registrationID: registrationID, input: nil))
        if holdUnregistration {
            try await withCheckedThrowingContinuation { pendingUnregistrations.append($0) }
        }
        completedUnregistrations += 1
    }

    func releaseUnregistration() {
        holdUnregistration = false
        let requests = pendingUnregistrations
        pendingUnregistrations = []
        for request in requests { request.resume() }
    }

    func close() {
        controller.shutdown()
        for request in pending { request.resume(throwing: CancellationError()) }
        pending = []
        #expect(pendingUnregistrations.isEmpty)
        for request in pendingUnregistrations { request.resume(throwing: CancellationError()) }
        pendingUnregistrations = []
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor @Observable
private final class FollowActivities {
    var activities: [FollowActivity] = []
    var missingToken = false

    var client: ChannelActivityClient {
        ChannelActivityClient(activities: { self.activities }, request: { attributes, state in
            let activity = FollowActivity(attributes: attributes, content: state,
                                          token: self.missingToken ? nil : Data([1]))
            self.activities.append(activity)
            return activity
        })
    }
}

@MainActor @Observable
private final class FollowActivity: ChannelActivitySession {
    struct Ending {
        let state: ChannelActivityAttributes.ContentState
        let dismissAt: Date?
    }

    let id = UUID().uuidString
    let attributes: ChannelActivityAttributes
    var content: ChannelActivityAttributes.ContentState
    var isActive = true
    var pushToken: Data?
    var endings: [Ending] = []
    private(set) var tokenStreamsStarted = 0
    @ObservationIgnored private var tokens: [AsyncStream<Data>.Continuation] = []
    @ObservationIgnored private var states: [AsyncStream<Bool>.Continuation] = []

    init(attributes: ChannelActivityAttributes, content: ChannelActivityAttributes.ContentState, token: Data?) {
        self.attributes = attributes
        self.content = content
        pushToken = token
    }

    var pushTokenUpdates: AsyncStream<Data> {
        tokenStreamsStarted += 1
        return AsyncStream { continuation in
            if let pushToken {
                tokens.append(continuation)
                continuation.yield(pushToken)
            } else { continuation.finish() }
        }
    }

    var activeUpdates: AsyncStream<Bool> {
        AsyncStream { continuation in
            states.append(continuation)
            continuation.yield(isActive)
        }
    }

    func rotate(_ token: Data) {
        pushToken = token
        for continuation in tokens { continuation.yield(token) }
    }

    func update(_ state: ChannelActivityAttributes.ContentState) async { content = state }

    func end(_ state: ChannelActivityAttributes.ContentState, dismissAt: Date?) async {
        content = state
        isActive = false
        endings.append(Ending(state: state, dismissAt: dismissAt))
        for continuation in states { continuation.yield(false) }
    }
}
