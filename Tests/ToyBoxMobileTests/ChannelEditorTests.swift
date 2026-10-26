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
            #expect(labels.contains("Name and purpose changes appear in the conversation.") == editing)
            #expect(session.channel?.directory == originalDirectory)
        }
    }

    private func descendants(in view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }
    #endif

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
