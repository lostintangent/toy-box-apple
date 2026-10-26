import ChannelClient
import ChannelKit
import Foundation
import SwiftUI
import Testing
@testable import ToyBoxMobile

@Suite("Mobile Shell")
@MainActor
struct ShellTests {
    private func withDefaults(_ work: (UserDefaults) async throws -> Void) async rethrows {
        let name = "mobile-shell-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await work(defaults)
    }

    @Test func launchOverridesAreSessionOnlyAndTakePrecedence() async throws {
        await withDefaults { defaults in
            defaults.set("https://saved.example/prefix", forKey: "serverURL")
            let command = AppModel(arguments: ["app", "--server", "https://argument.example/prefix"],
                                   environment: ["TOY_BOX_SERVER_URL": "https://environment.example"],
                                   defaults: defaults)
            #expect(command.serverURL == "https://argument.example/prefix")
            let environment = AppModel(arguments: [], environment: ["TOY_BOX_SERVER_URL": "https://environment.example"],
                                       defaults: defaults)
            #expect(environment.serverURL == "https://environment.example")
            let saved = AppModel(arguments: [], environment: [:], defaults: defaults)
            #expect(saved.serverURL == "https://saved.example/prefix")
            #expect(defaults.string(forKey: "serverURL") == "https://saved.example/prefix")
        }
    }

    @Test func missingAndInvalidLaunchAddressesNeverChooseAnotherServer() async {
        await withDefaults { defaults in
            defaults.set("https://saved.example", forKey: "serverURL")
            for arguments in [["--server"], ["--server", ""], ["--server", "not-a-server"]] {
                let model = AppModel(arguments: arguments, environment: [:], defaults: defaults)
                #expect(model.catalog == nil)
                #expect(model.configurationError != nil)
                #expect(defaults.string(forKey: "serverURL") == "https://saved.example")
            }
            let emptyEnvironment = AppModel(arguments: [], environment: ["TOY_BOX_SERVER_URL": ""],
                                            defaults: defaults)
            #expect(emptyEnvironment.catalog == nil)
            #expect(emptyEnvironment.configurationError != nil)
        }
    }

    @Test func firstLaunchAndUnavailableBrowserLinksStayExplicit() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: [], environment: [:], defaults: defaults)
            #expect(model.catalog == nil)
            #expect(model.configurationError == nil)
            model.openInToyBox(channelID: "first")
            #expect(model.browserFailure?.url == nil)
            #expect(model.browserFailure?.message.isEmpty == false)
            try model.configure(serverURL: "https://fixture.example")
            #expect(model.browserFailure == nil)
        }
    }

    @Test func channelRowsKeepTheirMinimumAndGrowForAccessibilityText() {
        let channel = Channel(id: "layout", name: "A team with a deliberately long channel name",
                              directory: "/Projects/a-deliberately-long-folder-name",
                              model: .init(provider: "test", name: "test"), updatedAt: "2026-10-25T12:00:00Z")
        let lead = ChannelAgent.lead(id: channel.id, profile: .init(
            name: "Lead", role: "Coordinator", avatar: .init(mark: "M4 12H20", color: "#123456")
        ))
        func fitted(_ size: DynamicTypeSize) -> CGSize {
            let host = UIHostingController(rootView: ChannelSidebarRow(
                channel: channel, agents: [lead], working: [lead], attention: .waiting,
                now: Date(timeIntervalSince1970: 1_793_000_000)
            ).environment(\.dynamicTypeSize, size))
            host.loadViewIfNeeded()
            return host.sizeThatFits(in: CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
        }
        let regular = fitted(.large)
        let accessible = fitted(.accessibility5)
        #expect(regular.height >= 96)
        #expect(accessible.height > regular.height)
    }

    @Test func storesAndInteractionSurviveNavigationAndInactiveStopsTheConnection() async throws {
        await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            model.selectedChannelID = "first"
            let store = model.selectedStore
            let interaction = model.interaction(for: "first")
            interaction.messageView = .yours
            interaction.reveal(sequence: 42)
            model.setActive(true)
            #expect(store?.phase == .connecting)
            model.setActive(false)
            #expect(store?.phase == .idle)
            #expect(model.catalog?.isActive == false)
            model.selectedChannelID = "second"
            model.selectedChannelID = "first"
            #expect(model.selectedStore === store)
            #expect(model.interaction(for: "first") === interaction)
            #expect(interaction.messageView == .yours)
            #expect(interaction.revealRequest?.sequence == 42)
            #expect(model.selectedStore?.phase == .idle)
        }
    }

    @Test func managementOwnersResumeWithoutASelectedChannelOnlyWhileActive() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            defer { model.setActive(false) }
            let store = try #require(model.catalog?.channel(id: "first"))
            model.acquire(store)
            #expect(model.selectedChannelID == nil)
            #expect(store.phase == .idle)
            model.setActive(true)
            #expect(store.phase == .connecting)
            model.setActive(false)
            #expect(store.phase == .idle)
            model.setActive(true)
            #expect(store.phase == .connecting)
            model.selectedChannelID = store.id
            #expect(model.selectedStore === store)
            model.release(store)
            #expect(store.phase == .connecting)
        }
    }

    @Test func restorationWaitsForTheCatalogAndUsesTheNormalizedServer() async throws {
        await withDefaults { defaults in
            defaults.set(["https://fixture.example/prefix": "second"], forKey: "lastChannelByServer")
            let model = AppModel(arguments: ["--server", "HTTPS://FIXTURE.EXAMPLE:443/prefix/"],
                                 environment: [:], defaults: defaults, session: fixtureSession())
            model.reconcileSelection()
            #expect(model.selectedChannelID == nil)
            await model.refreshCatalog()
            #expect(model.selectedChannelID == "second")
            #expect(model.selectedStore === model.catalog?.channel(id: "second"))
            #expect(model.navigationNotice == nil)
        }
    }

    @Test func aMissingRememberedChannelExplainsTheLossWithoutSelectingTheFirstRow() async throws {
        await withDefaults { defaults in
            defaults.set(["https://fixture.example": "deleted"], forKey: "lastChannelByServer")
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            await model.refreshCatalog()
            #expect(model.catalog?.channels.count == 2)
            #expect(model.selectedChannelID == nil)
            #expect(model.navigationNotice != nil)
            #expect(defaults.dictionary(forKey: "lastChannelByServer")?.isEmpty == true)
            model.navigationNotice = nil
            model.reconcileSelection()
            #expect(model.navigationNotice == nil)
        }
    }

    @Test func changingServerDropsTheOldStoreAndInteractionWithoutOverwritingItsSavedSelection() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://first.example"], environment: [:],
                                 defaults: defaults)
            model.selectedChannelID = "first"
            let previousStore = model.selectedStore
            let previousInteraction = model.interaction(for: "first")
            try model.configure(serverURL: "https://second.example")
            #expect(model.selectedStore == nil)
            #expect(previousStore?.phase == .idle)
            #expect(model.interaction(for: "first") !== previousInteraction)
            #expect(defaults.dictionary(forKey: "lastChannelByServer")?["https://first.example"] as? String == "first")
            #expect(defaults.string(forKey: "serverURL") == "https://second.example")
        }
    }

    @Test func composerSessionsSurviveNavigationAndAreScopedToTheCurrentServer() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://first.example"], environment: [:],
                                 defaults: defaults)
            model.selectedChannelID = "first"
            let first = try #require(model.selectedStore)
            let session = model.composerSession(for: first)
            model.selectedChannelID = "second"
            let second = try #require(model.selectedStore)
            weak let secondSession: ComposerSession? = model.composerSession(for: second)
            #expect(secondSession != nil)
            #expect(secondSession !== session)
            model.selectedChannelID = nil
            model.selectedChannelID = "first"
            #expect(model.composerSession(for: first) === session)

            let replacement = ChannelStore(id: first.id, api: first.api)
            #expect(model.composerSession(for: replacement) !== session)
            try model.configure(serverURL: "https://second.example")
            #expect(secondSession == nil)
            model.selectedChannelID = "first"
            let changedServer = try #require(model.selectedStore)
            #expect(model.composerSession(for: changedServer) !== session)
            #expect(model.composerSession(for: changedServer).store === changedServer)
        }
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShellFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ShellFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                        headerFields: ["Content-Type": "application/json"]))
            let catalog = ChannelCatalog(
                lead: .init(name: "Lead", role: "Coordinator", avatar: .init(mark: "M4 12H20", color: "#123456")),
                channels: ["first", "second"].map {
                    Channel(id: $0, name: $0, model: .init(provider: "test", name: "test"),
                            updatedAt: "2026-10-25T12:00:00Z")
                }
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(catalog))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
