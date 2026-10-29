import ChannelClient
import ChannelKit
import SwiftUI
import Testing
import ToyBoxUI
import UIKit
@testable import ToyBoxMobile

@MainActor
struct ChannelEditorTests {
    @Test(arguments: ["", "  ", "  A purpose  "])
    func phoneCreationAlwaysOmitsTheFolderFromItsEncodedRequest(purpose: String) async throws {
        try await withFixture(editing: false) { _, session, _, editor in
            let model = ModelConfiguration(provider: "test", name: "test")
            session.name = "  Discussion  "
            session.purpose = purpose
            let input = editor.creationInput(model: model)
            let payload = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(input))
            let trimmed = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
            var expected: [String: JSONValue] = [
                "name": .string("Discussion"),
                "model": .object(["provider": .string("test"), "name": .string("test")])
            ]
            if !trimmed.isEmpty { expected["purpose"] = .string(trimmed) }
            #expect(payload == .object(expected))
            #expect(input.directory == nil)
        }
    }

    #if DEBUG
    @Test(arguments: [false, true], [ColorScheme.light, .dark])
    func phoneFormsLabelNameAndNeverShowAFolderRow(editing: Bool, scheme: ColorScheme) async throws {
        try await withFixture(editing: editing) { app, session, sessions, editor in
            let originalDirectory = session.channel?.directory
            session.focus = nil
            let host = UIHostingController(rootView: editor
                .environment(app)
                .environment(sessions)
                .environment(OverviewPresentation())
                .environment(\.colorScheme, scheme)
                .dynamicTypeSize(.large))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 900))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            await Task.yield()
            host.view.layoutIfNeeded()
            let tree = MobileAutomationTree(windows: [window])
            let labels = tree.elements.map(\.label)
            #expect(tree.elements.contains { $0.identifier == "channel-name-label" && $0.label == "Name" },
                    "The visible Name label must not be only a text-field accessibility label: \(tree.labels)")
            // SwiftUI's UIKit inputs are omitted by this in-process accessibility walker.
            let views = descendants(in: host.view)
            let names = views.compactMap { $0 as? UITextField }
            let purposes = views.compactMap { $0 as? UITextView }
            #expect(names.count == 1)
            #expect(purposes.count == 1)
            let name = try #require(names.first)
            let purpose = try #require(purposes.first)
            #expect(name.window === window && !name.isHidden && name.bounds.width > 0)
            #expect(purpose.window === window && !purpose.isHidden && purpose.bounds.height > 0)
            #expect(name.text == session.name)
            #expect(name.placeholder == "Required")
            #expect(name.isEnabled)
            #expect(purpose.text == session.purpose)
            #expect(purpose.isEditable)
            #expect(!tree.elements.contains { $0.identifier == "channel-directory" })
            for removed in ["Working directory", "Folder on Mac", "Optional",
                            "A folder on the server. Leave it empty for a discussion-only channel.",
                            "The lead starts right away and adds specialists as needed."] {
                #expect(!labels.contains { $0.contains(removed) })
            }
            #expect(!labels.contains("Name and purpose changes appear in the conversation."))
            #expect(session.channel?.directory == originalDirectory)
        }
    }

    @Test(arguments: [false, true], [ColorScheme.light, .dark])
    func phoneMemberFormsLabelNameAskForTheRoleAndShowNoNote(editing: Bool, scheme: ColorScheme) async throws {
        try await withMemberFixture(editing: editing) { app, session, sessions, editor in
            session.focus = nil
            let host = UIHostingController(rootView: editor
                .environment(app)
                .environment(sessions)
                .environment(OverviewPresentation())
                .environment(\.colorScheme, scheme)
                .dynamicTypeSize(.large))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 900))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            await Task.yield()
            host.view.layoutIfNeeded()
            let tree = MobileAutomationTree(windows: [window])
            let labels = tree.elements.map(\.label)
            let label = try #require(tree.elements.first { $0.identifier == "member-name-label" && $0.label == "Name" },
                                     "The visible Name label must not be only a text-field accessibility label: \(tree.labels)")
            let views = descendants(in: host.view)
            let names = views.compactMap { $0 as? UITextField }
            let roles = views.compactMap { $0 as? UITextView }
            #expect(names.count == 1)
            #expect(roles.count == 1)
            let name = try #require(names.first)
            let role = try #require(roles.first)
            let field = name.convert(name.bounds, to: window)
            #expect(abs(field.midY - label.frame.midY) <= 2 && field.minX >= label.frame.maxX,
                    "Name's field should trail its label on one row: label \(label.frame), field \(field)")
            #expect(name.text == session.name)
            #expect(name.placeholder == "Required")
            #expect(role.text == session.role && role.isEditable)
            let placeholder = try #require(descendants(in: role).compactMap { $0 as? UILabel }.first,
                                           "SwiftUI's vertical field keeps its prompt in a UILabel")
            #expect(placeholder.text == "What is this agent's role in the channel?")
            #expect((!placeholder.isHidden && placeholder.alpha > 0) == !editing,
                    "Role prompt hidden \(placeholder.isHidden), alpha \(placeholder.alpha)")
            #expect(labels.contains { $0.contains("Names are unique in this channel.") })
            for removed in ["Joins", "starts onboarding", "Member of", "What this agent owns"] {
                #expect(!labels.contains { $0.contains(removed) })
            }
        }
    }

    private func descendants(in view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }
    #endif

    @Test func memberConfirmationsUseShortVerbs() {
        #expect(MemberEditor.submitTitle(adding: true, saving: false) == "Add")
        #expect(MemberEditor.submitTitle(adding: true, saving: true) == "Adding…")
        #expect(MemberEditor.submitTitle(adding: false, saving: false) == "Save")
        #expect(MemberEditor.submitTitle(adding: false, saving: true) == "Saving…")
    }

    private func withMemberFixture<Result>(
        editing: Bool,
        _ body: (AppModel, ManagementSession, ManagementSessions, MemberEditor) async throws -> Result
    ) async throws -> Result {
        try await withFixture(editing: false) { app, _, sessions, _ in
            let api = try #require(app.api)
            let store = ChannelStore(id: "channel", api: api)
            let presenter = ManagementPresenter()
            let flow: ManagementFlow = editing
                ? .editMember(channelId: "channel", agentId: "ada")
                : .addMember(channelId: "channel", name: "")
            presenter.present(flow)
            let session = sessions.session(for: flow, catalog: try #require(app.catalog))
            let channel = ChannelDetails(Channel(
                id: "channel", name: "Discussion", model: .init(provider: "test", name: "test"),
                updatedAt: "2026-10-26T12:00:00Z"))
            let member = editing ? ChannelMember(id: "ada", name: "Ada", role: "Builds the phone Overview.") : nil
            session.load(channel: channel, member: member)
            return try await body(app, session, sessions,
                                  MemberEditor(channel: channel, store: store, presenter: presenter,
                                               session: session, host: nil))
        }
    }
    private func withFixture<Result>(
        editing: Bool,
        _ body: (AppModel, ManagementSession, ManagementSessions, ChannelEditor) async throws -> Result
    ) async throws -> Result {
        let suite = "phone-channel-editor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChannelEditorFixtureProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let app = AppModel(arguments: ["--server", "https://channel-editor.invalid"],
                           environment: [:], defaults: defaults, session: transport)
        let sessions = ManagementSessions()
        let presenter = ManagementPresenter()
        let flow: ManagementFlow = editing ? .editChannel(channelId: "channel") : .newChannel
        presenter.present(flow)
        let session = sessions.session(for: flow, catalog: try #require(app.catalog))
        if editing {
            session.load(channel: ChannelDetails(Channel(
                id: "channel", name: "Discussion", purpose: "Keep purpose unchanged",
                directory: "/Existing/server/folder", model: .init(provider: "test", name: "test"),
                updatedAt: "2026-10-26T12:00:00Z")), member: nil)
        }
        return try await body(app, session, sessions,
                              ChannelEditor(store: nil, presenter: presenter, session: session, host: nil))
    }
}

private final class ChannelEditorFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"Fixture has no model catalog."}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
