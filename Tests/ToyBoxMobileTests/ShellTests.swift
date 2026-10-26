import ChannelClient
import ChannelIntelligence
import ChannelKit
import Foundation
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
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

    @Test func theTrayUsesTheMeasuredHeightAndScaledMinimumWithoutDroppingBelowTheFloor() {
        #expect(!ChannelScreen.showsTray(usableHeight: 659, minimumHeight: 660))
        #expect(ChannelScreen.showsTray(usableHeight: 660, minimumHeight: 660))
        #expect(ChannelScreen.showsTray(usableHeight: 661, minimumHeight: 660))
        #expect(!ChannelScreen.showsTray(usableHeight: 659, minimumHeight: 600))
        #expect(ChannelScreen.showsTray(usableHeight: 660, minimumHeight: 600))
        #expect(!ChannelScreen.showsTray(usableHeight: 824, minimumHeight: 825))
        #expect(ChannelScreen.showsTray(usableHeight: 825, minimumHeight: 825))
    }

    @Test func launchOverridesAreSessionOnlyAndTakePrecedence() async throws {
        await withDefaults { defaults in
            defaults.set("https://saved.example/prefix", forKey: "serverURL")
            let command = AppModel(arguments: ["app", "--server", "https://argument.example/prefix"],
                                   environment: ["TOY_BOX_SERVER_URL": "https://environment.example"],
                                   bundleDefaultServerURL: "https://bundle.example",
                                   defaults: defaults)
            #expect(command.serverURL == "https://argument.example/prefix")
            let environment = AppModel(arguments: [], environment: ["TOY_BOX_SERVER_URL": "https://environment.example"],
                                       bundleDefaultServerURL: "https://bundle.example",
                                       defaults: defaults)
            #expect(environment.serverURL == "https://environment.example")
            let saved = AppModel(arguments: [], environment: [:], bundleDefaultServerURL: "https://bundle.example",
                                 defaults: defaults)
            #expect(saved.serverURL == "https://saved.example/prefix")
            #expect(defaults.string(forKey: "serverURL") == "https://saved.example/prefix")
        }
    }

    @Test func theBundleServerDefaultIsUsedWithoutPersistingAndSavedSettingsWinOnRelaunch() async throws {
        try await withDefaults { defaults in
            let installed = AppModel(arguments: [], environment: [:],
                                     bundleDefaultServerURL: "http://fixture.local:3100/prefix", defaults: defaults)
            #expect(installed.serverURL == "http://fixture.local:3100/prefix")
            #expect(installed.configurationError == nil)
            #expect(installed.catalog != nil)
            #expect(defaults.string(forKey: "serverURL") == nil)
            try installed.configure(serverURL: "https://chosen.example")
            let relaunched = AppModel(arguments: [], environment: [:],
                                      bundleDefaultServerURL: "http://fixture.local:3100/prefix", defaults: defaults)
            #expect(relaunched.serverURL == "https://chosen.example")
            #expect(defaults.string(forKey: "serverURL") == "https://chosen.example")
        }
    }

    @Test(arguments: ["", "not-a-server"])
    func invalidBundleDefaultsReportConfigurationErrors(address: String) async {
        await withDefaults { defaults in
            let model = AppModel(arguments: [], environment: [:], bundleDefaultServerURL: address, defaults: defaults)
            #expect(model.catalog == nil)
            #expect(model.configurationError != nil)
            #expect(model.serverURL == address)
            #expect(defaults.string(forKey: "serverURL") == nil)
        }
    }

    @Test func anInvalidSavedServerNeverFallsBackToTheBundle() async {
        await withDefaults { defaults in
            defaults.set("not-a-server", forKey: "serverURL")
            let model = AppModel(arguments: [], environment: [:],
                                 bundleDefaultServerURL: "https://bundle.example", defaults: defaults)
            #expect(model.catalog == nil)
            #expect(model.configurationError != nil)
            #expect(model.serverURL == "not-a-server")
            #expect(defaults.string(forKey: "serverURL") == "not-a-server")
        }
    }

    @Test func missingAndInvalidLaunchAddressesNeverChooseAnotherServer() async {
        await withDefaults { defaults in
            defaults.set("https://saved.example", forKey: "serverURL")
            for arguments in [["--server"], ["--server", ""], ["--server", "not-a-server"]] {
                let model = AppModel(arguments: arguments, environment: [:],
                                     bundleDefaultServerURL: "https://bundle.example", defaults: defaults)
                #expect(model.catalog == nil)
                #expect(model.configurationError != nil)
                #expect(defaults.string(forKey: "serverURL") == "https://saved.example")
            }
            let emptyEnvironment = AppModel(arguments: [], environment: ["TOY_BOX_SERVER_URL": ""],
                                            bundleDefaultServerURL: "https://bundle.example",
                                            defaults: defaults)
            #expect(emptyEnvironment.catalog == nil)
            #expect(emptyEnvironment.configurationError != nil)
        }
    }

    @Test func firstLaunchAndUnavailableBrowserLinksStayExplicit() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: [], environment: [:], bundleDefaultServerURL: nil, defaults: defaults)
            #expect(model.catalog == nil)
            #expect(model.configurationError == nil)
            model.openInToyBox(channelID: "first")
            #expect(model.browserFailure?.url == nil)
            #expect(model.browserFailure?.message.isEmpty == false)
            try model.configure(serverURL: "https://fixture.example")
            #expect(model.browserFailure == nil)
        }
    }

    @Test func focusedRefreshHasStableDestinationIdentityInsteadOfARecreatedClosure() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            let catalog = ChannelRefreshTarget.catalog(model)
            #expect(catalog == .catalog(model))
            let otherModel = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                      defaults: defaults, session: fixtureSession())
            #expect(catalog != .catalog(otherModel))
            let store = try #require(model.catalog?.channel(id: "first"))
            #expect(ChannelRefreshTarget.channel(store) == .channel(store))
            #expect(catalog != .channel(store))
            let replacement = ChannelStore(id: store.id, api: store.api)
            #expect(ChannelRefreshTarget.channel(store) != .channel(replacement))
        }
    }

    @Test func focusedConversationRefreshReconnectsOnlyItsStore() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            let store = try #require(model.catalog?.channel(id: "first"))
            let other = try #require(model.catalog?.channel(id: "second"))
            defer { store.disconnect() }
            #expect(ChannelRefreshTarget.channel(store).perform() == nil)
            #expect(store.phase == .connecting)
            #expect(other.phase == .idle)
            #expect(model.catalog?.hasLoaded == false)
        }
    }

    @Test func focusedCatalogRefreshUsesTheCurrentServerWithoutChangingItsFocusIdentity() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://first.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            let target = ChannelRefreshTarget.catalog(model)
            let previousCatalog = model.catalog
            try model.configure(serverURL: "https://second.example/prefix")
            #expect(target == .catalog(model))
            await target.perform()?.value
            #expect(model.catalog !== previousCatalog)
            #expect(model.catalog?.api.baseURL.absoluteString == "https://second.example/prefix")
            #expect(model.catalog?.hasLoaded == true)
            #expect(model.catalog?.channels.count == 2)
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
        #expect(regular.height >= 72)
        #expect(accessible.height > regular.height)
    }

    @Test(arguments: [240.0, 386.0])
    func channelRowsUseTwoLinesWithoutAnEmptyWorkingLine(width: Double) {
        let channel = Channel(id: "layout", name: "Workshop", directory: "/Projects/Workshop",
                              model: .init(provider: "test", name: "test"), updatedAt: "2026-10-25T12:00:00Z")
        let agents = (0..<4).map { index in
            ChannelAgent.lead(id: "agent-\(index)", profile: .init(
                name: "Agent \(index)", role: "Coordinator", avatar: .init(mark: "M4 12H20", color: "#123456")
            ))
        }
        func height(working: [ChannelAgent], attention: ChannelAttention?) -> CGFloat {
            let host = UIHostingController(rootView: ChannelSidebarRow(
                channel: channel, agents: agents, working: working, attention: attention,
                now: Date(timeIntervalSince1970: 1_793_000_000)
            ).environment(\.dynamicTypeSize, .large))
            host.loadViewIfNeeded()
            return host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        }
        let title = UIHostingController(rootView: Text(channel.name).font(.headline)
            .environment(\.dynamicTypeSize, .large))
        title.loadViewIfNeeded()
        let titleHeight = title.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        let workingHeight = max(72, titleHeight + 8 + 20 + 24)
        #expect(height(working: [], attention: nil) == 72)
        #expect(height(working: agents, attention: nil) == workingHeight)
        #expect(height(working: agents, attention: .waiting) == workingHeight)
    }

    @Test(arguments: [false, true])
    func aReaderWaitsForActualCompactOverviewDismissalNotJustTheClosedIntent(imageReader: Bool) {
        let overview = OverviewPresentation()
        overview.compactSheetDidAppear()
        func visibility(requested: Bool = true, overviewRequested: Bool) -> ChannelReaderVisibility {
            ChannelReaderVisibility(artifactRequested: requested && !imageReader,
                                    imageRequested: requested && imageReader, compactOverviewRequested: overviewRequested,
                                    compactOverviewPresented: overview.isCompactSheetPresented)
        }
        #expect(!visibility(overviewRequested: true).isVisible)
        #expect(!visibility(overviewRequested: false).isVisible)
        overview.compactSheetDidDismiss(isRequested: false)
        #expect(visibility(overviewRequested: false).isVisible)
        #expect(!visibility(requested: false, overviewRequested: false).isVisible)
    }

    @Test func changingChannelsClearsReaderCoverageWithoutReplacingTheConversationState() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            model.selectedChannelID = "first"
            let store = try #require(model.selectedStore)
            let interaction = model.interaction(for: store.id)
            let composer = model.composerSession(for: store)
            let artifacts = model.artifactSession(for: store)
            let gallery = model.galleryPresenter(for: store)
            gallery.open(images: [.init(name: "image.png", url: "/image.png")], at: 0,
                         source: .init(messageID: "image", sender: "Lead", timestamp: "2026-10-25T12:00:00Z"),
                         api: store.api)
            interaction.isArtifactViewerPresented = true
            model.selectedChannelID = "second"
            #expect(!interaction.isArtifactViewerPresented)
            #expect(gallery.session == nil)
            model.selectedChannelID = "first"
            #expect(model.selectedStore === store)
            #expect(model.interaction(for: store.id) === interaction)
            #expect(model.composerSession(for: store) === composer)
            #expect(model.artifactSession(for: store) === artifacts)
            #expect(model.galleryPresenter(for: store) === gallery)
        }
    }

    @Test(arguments: [false, true])
    func changingTheReaderStoreOrServerClosesItsScope(changingServer: Bool) async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            model.selectedChannelID = "first"
            let store = try #require(model.selectedStore)
            let interaction = model.interaction(for: store.id)
            let artifacts = model.artifactSession(for: store)
            let gallery = model.galleryPresenter(for: store)
            gallery.open(images: [.init(name: "image.png", url: "/image.png")], at: 0,
                         source: .init(messageID: "image", sender: "Lead", timestamp: "2026-10-25T12:00:00Z"),
                         api: store.api)
            interaction.isArtifactViewerPresented = true
            let replacement: ChannelStore
            if changingServer {
                try model.configure(serverURL: "https://second.example")
                replacement = try #require(model.catalog?.channel(id: store.id))
            } else {
                replacement = ChannelStore(id: store.id, api: store.api)
            }
            #expect(model.artifactSession(for: replacement) !== artifacts)
            #expect(model.galleryPresenter(for: replacement) !== gallery)
            #expect(gallery.session == nil)
            #expect(!interaction.isArtifactViewerPresented)
        }
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

    @Test func creationAvailabilityUsesTheSameCatalogConnectionAsTheSidebar() async throws {
        await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            defer { model.setActive(false) }
            #expect(model.sidebarConnection == .connecting)
            #expect(!model.canCreateChannel)
            #expect(!model.canManageChannels)
            await model.refreshCatalog()
            #expect(model.sidebarConnection == .connected)
            #expect(!model.canCreateChannel)
            #expect(!model.canManageChannels)
            model.setActive(true)
            #expect(model.canCreateChannel)
            #expect(model.selectedChannelID == nil)
            #expect(model.canManageChannels)
            model.selectedChannelID = "second"
            #expect(model.canManageChannels)
            model.setActive(false)
            #expect(!model.canCreateChannel)
            #expect(!model.canManageChannels)
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

    @Test func staleServerConfirmationLeavesTheCurrentServerAndSelectionUntouched() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://first.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            let confirmedOldAddress = model.serverURL
            try model.configure(serverURL: "https://second.example/prefix")
            model.selectedChannelID = "second"
            model.visibleChannelID = "second"
            let catalog = model.catalog
            let store = model.selectedStore
            let interaction = model.interaction(for: "second")
            #expect(throws: ServerSwitchFailure.self) {
                try model.switchServer(to: "https://third.example", replacing: confirmedOldAddress)
            }
            #expect(model.serverURL == "https://second.example/prefix")
            #expect(model.catalog === catalog)
            #expect(model.selectedStore === store)
            #expect(model.visibleChannelID == "second")
            #expect(model.interaction(for: "second") === interaction)
            #expect(defaults.string(forKey: "serverURL") == model.serverURL)
        }
    }

    @Test func invalidConfirmedServerDoesNotTearDownOrPersistOverTheCurrentOne() async throws {
        await withDefaults { defaults in
            defaults.set("https://saved.example", forKey: "serverURL")
            let model = AppModel(arguments: ["--server", "https://first.example"], environment: [:],
                                 defaults: defaults)
            model.selectedChannelID = "first"
            let catalog = model.catalog
            let store = model.selectedStore
            #expect(throws: ChannelAPIError.invalidServerURL) {
                try model.switchServer(to: "file:///not-a-server", replacing: model.serverURL)
            }
            #expect(model.serverURL == "https://first.example")
            #expect(model.catalog === catalog)
            #expect(model.selectedStore === store)
            #expect(defaults.string(forKey: "serverURL") == "https://saved.example")
        }
    }

    @Test func confirmedSwitchPreservesDraftNamespacesAndRestoresOnlyEachServersSelection() async throws {
        try await withDefaults { defaults in
            let namespace = UUID().uuidString.lowercased()
            let firstAddress = "https://first-\(namespace).example/prefix"
            let secondAddress = "https://second-\(namespace).example/prefix"
            let model = AppModel(arguments: ["--server", firstAddress], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            var drafts: [ComposerDraft] = []
            defer {
                model.setActive(false)
                for draft in drafts { draft.clear(ifUnchanged: draft.revision) }
                for address in [firstAddress, secondAddress] {
                    do {
                        let url = try #require(URL(string: address))
                        let key = ComposerDraft.storageKey(serverURL: url, channelID: "first")
                        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        let directory = support.appendingPathComponent("ToyBoxDesktop/Drafts/\(key)")
                        for path in [directory.appendingPathExtension("json"), directory]
                            where FileManager.default.fileExists(atPath: path.path) {
                            try FileManager.default.removeItem(at: path)
                        }
                    } catch { Issue.record(error) }
                }
            }
            model.selectedChannelID = "first"
            let firstStore = try #require(model.selectedStore)
            let firstDraft = model.composerSession(for: firstStore).draft
            drafts.append(firstDraft)
            firstDraft.text = "Draft for the first server"
            model.visibleChannelID = firstStore.id
            model.setActive(true)
            #expect(firstStore.phase == .connecting)
            try model.switchServer(to: secondAddress, replacing: firstAddress)
            #expect(firstStore.phase == .idle)
            #expect(model.selectedStore == nil)
            #expect(model.visibleChannelID == nil)
            #expect(defaults.string(forKey: "serverURL") == secondAddress)
            await model.refreshCatalog()
            #expect(model.selectedChannelID == nil)
            let secondStore = try #require(model.catalog?.channel(id: "first"))
            let secondDraft = model.composerSession(for: secondStore).draft
            drafts.append(secondDraft)
            #expect(secondDraft !== firstDraft)
            #expect(secondDraft.text.isEmpty)
            secondDraft.text = "Draft for the second server"
            model.selectedChannelID = "second"
            try model.switchServer(to: firstAddress, replacing: secondAddress)
            await model.refreshCatalog()
            #expect(model.selectedChannelID == "first")
            let restoredStore = try #require(model.selectedStore)
            #expect(model.composerSession(for: restoredStore).draft === firstDraft)
            #expect(firstDraft.text == "Draft for the first server")
            #expect(secondDraft.text == "Draft for the second server")
            #expect(defaults.dictionary(forKey: "lastChannelByServer")?[secondAddress] as? String == "second")
        }
    }

    @Test func firstLaunchRequiresARealCurrentProbeAndAllowsExplicitLoopbackTesting() async throws {
        let connection = ServerConnectionProbe(address: "http://127.0.0.1:3100/prefix", session: fixtureSession())
        let section = ServerConnectionSection(connection: connection, requiresTest: true, currentServer: nil,
                                              onUse: {}, useFailure: .constant(nil))
        #expect(section.canTest)
        #expect(!section.canUse)
        let operation = try #require(connection.start())
        #expect(!section.canTest)
        #expect(!section.canUse)
        await operation.value
        #expect(section.canUse)
        connection.address = "http://127.0.0.1:3100/another-prefix"
        #expect(section.canTest)
        #expect(!section.canUse)
        connection.address = "not-a-server"
        #expect(!section.canTest)
        #expect(!section.canUse)
    }

    @Test func settingsUseIsExplicitAndRejectsTheCurrentNormalizedServer() {
        let connection = ServerConnectionProbe(address: "HTTPS://FIXTURE.EXAMPLE:443/prefix/")
        let section = ServerConnectionSection(connection: connection, requiresTest: false,
                                              currentServer: "https://fixture.example/prefix",
                                              onUse: {}, useFailure: .constant(nil))
        #expect(section.canTest)
        #expect(!section.canUse)
        connection.address = "https://another.example/prefix"
        #expect(section.canUse)
        connection.address = "https://user:password@another.example"
        #expect(!section.canTest)
        #expect(!section.canUse)
    }

    @Test func settingsFailuresKeepTheirRealCategoryAndPhoneAvailabilityReason() {
        enum Key: String, CodingKey { case lead }
        let missingLead = DecodingError.keyNotFound(Key.lead, .init(codingPath: [], debugDescription: "Missing Lead"))
        #expect(ServerConnectionSection.failureMessage(missingLead).contains("required Lead"))
        #expect(ServerConnectionSection.failureMessage(ChannelAPIError.http(status: 403, message: "Forbidden"))
            .hasPrefix("Authorization error:"))
        #expect(ServerConnectionSection.failureMessage(URLError(.serverCertificateUntrusted))
            .hasPrefix("TLS connection error:"))
        #expect(ServerConnectionSection.failureMessage(URLError(.cannotConnectToHost))
            .hasPrefix("Connection error:"))
        #expect(SettingsView.unavailableText(.deviceNotEligible) == "This iPhone doesn't support Apple Intelligence.")
        #expect(SettingsView.unavailableText(.unsupportedLanguage).contains("iPhone's language"))
        #expect(SettingsView.unavailableText(.appleIntelligenceNotEnabled).contains("Open Settings"))
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

    @Test func draftCopyPreservesTextAndOriginalImageBytesWithoutChangingTheDraft() async throws {
        let draft = ComposerDraft(imageIsReadable: { _ in true })
        draft.text = "A draft to keep\nwith its original spacing."
        let bytes = try #require(draftImage().pngData())
        draft.append(.init(name: "Original image.png", mimeType: "image/png", data: bytes))
        draft.associateSend(id: "unconfirmed-attempt")
        let revision = draft.revision
        let providers = DraftPasteboard.itemProviders(for: draft)
        #expect(providers.count == 2)
        let text = try await copiedData(from: providers[0], type: .utf8PlainText)
        #expect(String(data: text, encoding: .utf8) == draft.text)
        #expect(providers[1].suggestedName == "Original image.png")
        let image = try await copiedData(from: providers[1], type: .png)
        #expect(image == bytes)
        #expect(draft.revision == revision)
        #expect(draft.sendAttemptID == "unconfirmed-attempt")
        #expect(draft.images.first?.data == bytes)
    }

    @Test func imageOnlyDraftsRemainCopyableAndEmptyDraftsHaveNothingToCopy() async throws {
        let draft = ComposerDraft(imageIsReadable: { _ in true })
        #expect(!draft.hasContent)
        #expect(DraftPasteboard.itemProviders(for: draft).isEmpty)
        let bytes = try #require(draftImage().jpegData(compressionQuality: 0.8))
        draft.append(.init(name: "Draft image.jpg", mimeType: "image/jpeg", data: bytes))
        #expect(draft.hasContent)
        let providers = DraftPasteboard.itemProviders(for: draft)
        #expect(providers.count == 1)
        let provider = try #require(providers.first)
        #expect(provider.suggestedName == "Draft image.jpg")
        let copied = try await copiedData(from: provider, type: .jpeg)
        #expect(copied == bytes)
        #expect(draft.images.count == 1)
    }

    private func draftImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    private func copiedData(from provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
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
