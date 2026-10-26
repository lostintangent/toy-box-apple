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
        session.navigationPath = ["agent"]
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
        #expect(session.navigationPath == ["agent"])
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
        session.navigationPath = ["agent"]
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
