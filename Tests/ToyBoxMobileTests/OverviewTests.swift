import ChannelClient
import ChannelKit
import Foundation
import Testing
import SwiftUI
import ToyBoxUI
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

    private func withModel(_ body: (AppModel) throws -> Void) throws {
        let suite = "mobile-overview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppModel(arguments: ["--server", "https://fixture.example"], environment: [:], defaults: defaults))
    }
}
