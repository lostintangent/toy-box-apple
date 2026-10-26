import ChannelClient
import ChannelKit
import Foundation
import Testing
import SwiftUI
import ToyBoxUI
import UIKit
@testable import ToyBoxMobile

@Suite("Mobile Overview")
@MainActor
struct OverviewTests {
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

    @Test(arguments: [ColorScheme.light, .dark], [DynamicTypeSize.large, .accessibility5])
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

    @Test(arguments: [false, true])
    func plainOverviewUsesExactCollapsedAndExpandedNativeRowGaps(expanded: Bool) async throws {
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
        var frames: [CGRect] = []
        for section in 0..<list.numberOfSections {
            for item in 0..<list.numberOfItems(inSection: section) {
                frames.append(try #require(list.layoutAttributesForItem(
                    at: IndexPath(item: item, section: section))).frame)
            }
        }
        try #require(frames.count == (expanded ? 4 : 2))
        let first = try #require(frames.first)
        let top = list.convert(first, to: host.view).minY - host.view.safeAreaInsets.top
        #expect(abs(top - 12) < 0.5,
                "Top \(top), inset \(list.adjustedContentInset), offset \(list.contentOffset), frames \(frames)")
        if expanded {
            #expect(abs(first.height - 48) < 0.5)
            #expect(abs(frames[1].height - 44) < 0.5)
            #expect(abs(frames[1].minY - first.maxY) < 0.5)
            #expect(abs(frames[2].minY - frames[1].maxY - 16) < 0.5)
        } else {
            #expect(abs(first.height - 44) < 0.5)
            #expect(abs(frames[1].minY - first.maxY - 8) < 0.5)
            #expect(abs(frames[1].minY - first.minY - 52) < 0.5)
        }
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
    func artifactActionKeepsItsEnabledInkAndAnUncentered44PointTargetUnderLinkTint(
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
        #expect(image.size.height == 44)
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
        #expect(min(first, cgImage.height - 1 - last) < 8)
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
