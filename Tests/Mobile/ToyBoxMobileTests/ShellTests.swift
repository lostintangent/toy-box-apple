import AppIntents
import ChannelIntelligence
import ChannelKit
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing
import ToyBoxUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications
@testable import ChannelClient
@testable import ToyBoxMobile
@testable import ToyBoxMobileIntegrations

@Suite("Mobile Shell")
@MainActor
struct ShellTests {
    private func withDefaults(_ work: (UserDefaults) async throws -> Void) async rethrows {
        let name = "mobile-shell-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await work(defaults)
    }

    private func withRegistrationStore(_ work: (MobilePushRegistrationStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shell-push-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await work(MobilePushRegistrationStore(directory: directory))
    }

    private func withNotifications(
        enabled: Bool = false,
        register: @escaping (ChannelAPI, String, PushRegistration) async throws -> Bool = { _, _, _ in false },
        subscribe: @escaping (ChannelAPI, String, String) async throws -> Void = { _, _, _ in },
        unsubscribe: @escaping (ChannelAPI, String, String) async throws -> Void = { _, _, _ in },
        readAuthorization: @escaping () async -> UNAuthorizationStatus = { .authorized },
        removeDelivered: @escaping ([String]) -> Void = { _ in },
        setBadgeCount: @escaping (Int) async throws -> Void = { _ in },
        _ work: @MainActor (UserDefaults, MobileNotificationRegistration, ChannelNotifications) async throws -> Void
    ) async throws {
        try await withDefaults { defaults in
            defaults.set(enabled, forKey: "notificationsEnabled")
            try await withRegistrationStore { store in
                let api = try ChannelAPI(serverURL: "https://fixture.example")
                let registration = MobileNotificationRegistration(
                    store: store, environment: .sandbox, requestToken: {}, register: register,
                    remove: { _, _ in }, subscribe: subscribe, unsubscribe: unsubscribe)
                try registration.select(apis: [api])
                let notifications = ChannelNotifications(
                    defaults: defaults, registration: registration,
                    readAuthorization: readAuthorization, removeDelivered: removeDelivered,
                    setBadgeCount: setBadgeCount)
                notifications.configure(apis: [api])
                try await work(defaults, registration, notifications)
                await registration.waitUntilIdle()
            }
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    @Test func handoffUnavailableStaysVisibleWhenTheNormalPhoneRootIsReplaced() async {
        await withDefaults { defaults in
            let model = AppModel(arguments: [], environment: [:], defaults: defaults)
            let navigation = ChannelHandoffNavigation()
            let root = RootView(handoff: navigation).environment(model).environment(\.scenePhase, .inactive)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
            let host = UIHostingController(rootView: root)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            await navigation.continueActivity(NSUserActivity(activityType: ChannelHandoff.activityType),
                                              catalogs: { [] }) { _, _ in
                Issue.record("An invalid continuation opened a channel.")
            }
            host.rootView = root
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let labels = MobileAutomationTree(windows: [window]).elements.map(\.label)
            #expect(navigation.phase == .missing)
            #expect(labels.contains("Channel unavailable"), "\(labels)")
            #expect(labels.contains("This channel isn't available."), "\(labels)")
            #expect(labels.contains("Show Channels"), "\(labels)")
            #expect(model.selectedChannelID == nil)
        }
    }

    @Test func anInactiveSceneKeepsTheSidebarsWorkingAgents() async {
        await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            defer { model.setScenePhase(.background) }
            await model.refreshCatalog()
            let root = RootView(handoff: ChannelHandoffNavigation()).environment(model).environment(\.scenePhase, .inactive)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
            let host = UIHostingController(rootView: root)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            let values = MobileAutomationTree(windows: [window]).elements.map(\.value)
            #expect(!model.isActive)
            #expect(values.contains { $0.contains("Lead working") }, "\(values)")
        }
    }

    @Test(arguments: [false, true])
    func registrationErrorsAreShownOnlyWhileNotificationsAreEnabled(enabled: Bool) async throws {
        try await withNotifications(register: { _, _, _ in throw URLError(.cannotConnectToHost) }) {
            _, registration, notifications in
            if enabled { await notifications.enable() }
            else { await notifications.refreshAuthorization() }
            registration.receivedToken(Data([1]))
            await registration.waitUntilIdle()
            #expect(notifications.registrationError != nil)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
            let host = UIHostingController(rootView: Form {
                NotificationSettingsSection(notifications: notifications)
            })
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            let labels = MobileAutomationTree(windows: [window]).elements.map(\.label)
            #expect(labels.contains("Requests for your response") == enabled, "\(labels)")
            #expect(labels.contains("Completed tasks") == enabled, "\(labels)")
            #expect(labels.contains("Couldn't connect notifications to this server.") == enabled, "\(labels)")
            #expect(labels.contains("Try Again") == enabled, "\(labels)")
        }
    }

    @Test func serverCardKeepsTwoNativeRowsThroughATest() async throws {
        let connection = ServerConnectionProbe(address: "https://another.example/prefix", session: fixtureSession())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
        let host = UIHostingController(rootView: Form {
            ServerConnectionSection(connection: connection, placeholder: "Required", footer: "Footer",
                                    failure: .constant(nil))
        })
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        func rows() -> (heights: [CGFloat], test: MobileAutomationTree.Element?, labels: [String]) {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let cells = collectionCells(in: host.view)
            let tree = MobileAutomationTree(windows: [window])
            let button = tree.elements.first { $0.identifier == "server-test" }
            let test = button.flatMap { button in cells.first { $0.contains(CGPoint(x: button.frame.midX, y: button.frame.midY)) } }
            // The address field exposes no element in a test host, so its row is the cell right above Test Connection.
            let address = test.flatMap { test in cells.first { abs($0.maxY - test.minY) < 0.5 } }
            return ([address, test].compactMap { $0?.height }, button, tree.elements.map(\.label))
        }
        let idle = rows()
        #expect(idle.heights.count == 2, "\(idle.heights)")
        #expect((idle.heights.max() ?? 0) - (idle.heights.min() ?? 0) < 0.5, "\(idle.heights)")
        #expect((idle.heights.first ?? 0) >= 44, "\(idle.heights)")
        #expect(idle.test?.label == "Test Connection", "\(idle.labels)")
        #expect(idle.test?.value == "", "\(String(describing: idle.test))")
        let operation = try #require(connection.start())
        let connecting = rows()
        #expect(connecting.test?.label.hasPrefix("Connecting") == true, "\(connecting.labels)")
        #expect(connecting.heights == idle.heights, "\(connecting.heights) \(idle.heights)")
        await operation.value
        let connected = rows()
        #expect(connected.test?.label == "Test Connection", "\(connected.labels)")
        #expect(connected.test?.value == "Connected", "\(String(describing: connected.test))")
        #expect(connected.heights == idle.heights, "\(connected.heights) \(idle.heights)")
        connection.address = "https://another.example/other"
        #expect(rows().test?.value == "", "Editing the address clears the checkmark.")
    }

    /// Continue is pinned at default sizes and follows the card at accessibility sizes, where a bar would cover it.
    @Test(arguments: [DynamicTypeSize.large, .accessibility5])
    func welcomeKeepsContinueOnTheCardEdgesUntilATestPasses(size: DynamicTypeSize) async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: [], environment: [:], defaults: defaults, session: fixtureSession())
            // Tall enough that the inline row is laid out at accessibility sizes.
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: size.isAccessibilitySize ? 2400 : 678))
            let host = UIHostingController(rootView: NavigationStack { ConnectionSetupView() }
                .environment(\.dynamicTypeSize, size).environment(model))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            // Continue's insets come from the card's measured frame, which lands on the next pass.
            await Task.yield()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let tree = MobileAutomationTree(windows: [window])
            let labels = tree.elements.map(\.label)
            let proceed = try #require(tree.elements.first { $0.identifier == "server-use" }, "\(labels)")
            let test = try #require(tree.elements.first { $0.identifier == "server-test" }, "\(labels)")
            let cells = collectionCells(in: host.view)
            let card = try #require(cells.first { $0.contains(CGPoint(x: test.frame.midX, y: test.frame.midY)) })
            #expect(labels.contains("Welcome to Toy\u{00A0}Box\u{00A0}👋"), "\(labels)")
            #expect(proceed.label == "Continue")
            #expect(!proceed.isEnabled)
            #expect(abs(proceed.frame.minX - card.minX) < 1, "\(proceed.frame) \(card)")
            #expect(abs(proceed.frame.maxX - card.maxX) < 1, "\(proceed.frame) \(card)")
            #expect(proceed.frame.minY > card.maxY, "\(proceed.frame) \(card)")
            let isInline = cells.contains { $0.contains(CGPoint(x: proceed.frame.midX, y: proceed.frame.midY)) }
            #expect(isInline == size.isAccessibilitySize, "\(proceed.frame) \(cells)")
            if !size.isAccessibilitySize {
                #expect(proceed.frame.height >= 48 && proceed.frame.height <= 56, "\(proceed.frame)")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func settingsSwitchesWhenATestOfAnotherServerConnects() async throws {
        try await withDefaults { defaults in
            let notifications = ChannelNotifications(defaults: defaults, readAuthorization: { .notDetermined })
            let model = AppModel(arguments: ["--server", "https://fixture.example/prefix"], environment: [:],
                                 defaults: defaults, session: fixtureSession(), notifications: notifications)
            defer { model.setScenePhase(.background) }
            await model.refreshCatalog()
            let fixture = fixtureSession()
            let connection = ServerConnectionProbe(address: "", session: fixture) { api in
                if api.baseURL.host == "unreachable.example" { throw URLError(.cannotConnectToHost) }
                return try await api.catalog()
            }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
            let page = ServerSettingsView(catalog: model.catalog, connection: connection)
            let host = UIHostingController(rootView: NavigationStack { page }.environment(model))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds
            @MainActor func labels() -> [String] {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                return MobileAutomationTree(windows: [window]).elements.map(\.label)
            }
            _ = labels()
            #expect(connection.address == "https://fixture.example/prefix")

            await connection.start()?.value
            _ = labels()
            #expect(model.serverURL == "https://fixture.example/prefix", "Testing the server in use only confirms it.")

            connection.address = "https://unreachable.example"
            await connection.start()?.value
            let failed = labels()
            #expect(model.serverURL == "https://fixture.example/prefix", "A failed test changes nothing.")
            #expect(failed.contains { $0.hasSuffix("Still using fixture.example.") }, "\(failed)")

            connection.address = "https://another.example"
            await connection.start()?.value
            _ = labels()
            let another = ChannelWaitingRequest.normalizedServer("https://another.example")
            for await switched in Observations({
                ChannelWaitingRequest.normalizedServer(model.serverURL) == another && model.catalog?.phase == .connected
            }) where switched { break }
            let switched = MobileAutomationTree(windows: [window]).elements
            #expect(switched.first { $0.identifier == "server-test" }?.value == "Connected",
                    "\(switched.map(\.label))")
            #expect(model.catalogs.count == 1, "The page's server moved rather than adding another.")
        }
    }

    @Test func aCompactChannelWithoutAVerticalBarOpensItsActionsAndNamesYourMessagesFromATitleButton() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            defer { model.setScenePhase(.background) }
            await model.refreshCatalog()
            let root = RootView(handoff: ChannelHandoffNavigation()).environment(model).environment(\.scenePhase, .inactive)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let host = UIHostingController(rootView: root)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            model.selectedChannelID = "first"
            @MainActor func channelScreen() async -> UIViewController? {
                for _ in 0..<20 {
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    if let screen = navigationScreens(in: host).first(where: { titleButton(in: $0.navigationItem) != nil }) {
                        return screen
                    }
                    await Task.yield()
                }
                return nil
            }
            let screen = try #require(await channelScreen(),
                                      "\(navigationScreens(in: host).map { barDescription($0.navigationItem) })")
            let item = screen.navigationItem
            #expect(item.titleMenuProvider == nil, "The title is a button, so the system draws no chevron.")
            #expect(item.title == "first", "The screen still names itself for Back and VoiceOver.")
            // SwiftUI defers the menu's items until it opens, so only its presence is read here.
            let title = try #require(titleButton(in: item))
            #expect(title.menu != nil, "\(barDescription(item))")
            // This host keeps bar buttons out of the accessibility tree, so the bar is read from its navigation item.
            let barItems = (item.leadingItemGroups + item.trailingItemGroups).flatMap(\.barButtonItems)
                + (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
            #expect(barItems.filter { $0 !== title.item }.map(\.title) == ["Overview"], "\(barDescription(item))")
            #expect(item.additionalOverflowItems == nil)
            #expect(screen.navigationController?.isToolbarHidden == true)
            #expect(screen.toolbarItems?.isEmpty ?? true)
            #expect(title.item.accessibilityValue ?? "" == "", "All Messages leaves the name alone.")
            // The menu's items aren't readable here, so the filter is set as its picker would.
            model.interaction(for: "first").messageView = .yours
            @MainActor func titleValue() async -> String? {
                for _ in 0..<20 {
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    if let value = titleButton(in: item)?.item.accessibilityValue, !value.isEmpty { return value }
                    await Task.yield()
                }
                return nil
            }
            #expect(await titleValue() == "Your Messages", "Your Messages names itself under the channel's name.")
        }
    }

    /// The bar item that draws the channel's name, with the menu it opens.
    private func titleButton(in item: UINavigationItem) -> (item: UIBarButtonItem, menu: UIMenu?)? {
        for barItem in item.leadingItemGroups.flatMap(\.barButtonItems) + (item.leftBarButtonItems ?? []) {
            if let menu = barItem.menu { return (barItem, menu) }
            if let view = barItem.customView { return (barItem, buttonMenu(in: view)) }
        }
        return nil
    }

    private func buttonMenu(in view: UIView) -> UIMenu? {
        if let button = view as? UIButton, let menu = button.menu { return menu }
        return view.subviews.lazy.compactMap(buttonMenu).first
    }

    private func barDescription(_ item: UINavigationItem) -> String {
        (item.leadingItemGroups + item.trailingItemGroups).flatMap(\.barButtonItems)
            .map { "\($0.title ?? "custom view") menu: \($0.menu != nil)" }.joined(separator: ", ")
    }

    private func navigationScreens(in controller: UIViewController) -> [UIViewController] {
        var screens: [UIViewController] = []
        func visit(_ controller: UIViewController) {
            if let navigation = controller as? UINavigationController { screens += navigation.viewControllers }
            controller.children.forEach(visit)
        }
        visit(controller)
        return screens
    }

    private func collectionCells(in view: UIView) -> [CGRect] {
        var cells: [CGRect] = []
        func visit(_ view: UIView) {
            if let cell = view as? UICollectionViewCell, !cell.isHidden { cells.append(cell.convert(cell.bounds, to: nil)) }
            view.subviews.forEach(visit)
        }
        visit(view)
        return cells
    }

    #endif

    @Test func registrationKeepsItsAddressAndChangesOnlyNotificationTopicsWhenDisabled() async throws {
        try await withRegistrationStore { store in
            var tokenRequests = 0
            var inputs: [PushRegistration] = []
            var registeredIDs: [String] = []
            var deleted: [String] = []
            var topics: [String] = []
            let registration = MobileNotificationRegistration(
                store: store, environment: .production, requestToken: { tokenRequests += 1 },
                register: { _, id, input in
                    registeredIDs.append(id)
                    inputs.append(input)
                    return inputs.count == 1
                }, remove: { _, id in deleted.append(id) },
                subscribe: { _, _, topic in topics.append("on:\(topic)") },
                unsubscribe: { _, _, topic in topics.append("off:\(topic)") })
            try registration.select(apis: [ChannelAPI(serverURL: "https://first.example")])
            let id = try #require(registration.current.first?.registrationID)
            registration.update(enabled: true, requests: false, completions: true)
            #expect(tokenRequests == 1)
            #expect(inputs.isEmpty)
            #expect(!registration.isReady)
            registration.receivedToken(Data([0x00, 0x12, 0xab, 0xff]))
            await registration.waitUntilIdle()
            #expect(inputs == [PushRegistration(token: "0012abff", environment: .production)])
            #expect(registration.isReady)
            #expect(topics == ["off:requests", "on:completions"])
            registration.update(enabled: true, requests: false, completions: true)
            await registration.waitUntilIdle()
            #expect(inputs.count == 1)
            registration.update(enabled: true, requests: true, completions: false)
            await registration.waitUntilIdle()
            #expect(Array(topics.suffix(2)) == ["on:requests", "off:completions"])
            registration.update(enabled: false, requests: true, completions: false)
            await registration.waitUntilIdle()
            #expect(deleted.isEmpty)
            #expect(Array(topics.suffix(2)) == ["off:requests", "off:completions"])
            #expect(registration.current.first?.registrationID == id)
            #expect(registration.isReady)
            registration.update(enabled: true, requests: true, completions: false)
            await registration.waitUntilIdle()
            #expect(inputs.count == 4)
            #expect(registeredIDs == Array(repeating: id, count: 4))
            #expect(tokenRequests == 1)
            let previousTopics = topics
            registration.receivedToken(Data([2]))
            #expect(!registration.isReady)
            await registration.waitUntilIdle()
            #expect(registration.isReady)
            #expect(inputs.last == PushRegistration(token: "02", environment: .production))
            #expect(registeredIDs.last == id)
            #expect(topics == previousTopics + ["on:requests", "off:completions"])
        }
    }

    @Test(arguments: [false, true])
    func aTokenBeforeAuthorizationPreservesServerTopicsUntilChoicesAreKnown(enabled: Bool) async throws {
        try await withRegistrationStore { store in
            var registrations = 0
            var topics: [String] = []
            var created: [MobilePushRegistration] = []
            let registration = MobileNotificationRegistration(
                store: store, environment: .sandbox, requestToken: {},
                register: { _, _, _ in registrations += 1; return registrations == 1 },
                remove: { _, _ in }, subscribe: { _, _, topic in topics.append("on:\(topic)") },
                unsubscribe: { _, _, topic in topics.append("off:\(topic)") })
            registration.onCreated = { created.append($0) }
            try registration.select(apis: [ChannelAPI(serverURL: "https://fixture.example")])
            let selected = try #require(registration.current.first)
            registration.receivedToken(Data([1]))
            await registration.waitUntilIdle()
            #expect(registration.isReady)
            #expect(created == [selected])
            #expect(topics.isEmpty)

            registration.receivedToken(Data([2]))
            await registration.waitUntilIdle()
            #expect(registrations == 2)
            #expect(registration.isReady)
            #expect(topics.isEmpty)

            registration.update(enabled: enabled, requests: true, completions: false)
            await registration.waitUntilIdle()
            #expect(registrations == 3)
            #expect(registration.current == [selected])
            #expect(registration.isReady && registration.error == nil)
            #expect(topics == [enabled ? "on:requests" : "off:requests", "off:completions"])
        }
    }

    @Test(arguments: [false, true])
    func eachLaunchReconcilesBothTopicsAfterSuccessOrAPreferenceFailure(failedWrite: Bool) async throws {
        try await withRegistrationStore { store in
            var registrations = 0
            var topics: [String] = []
            var fails = failedWrite
            @MainActor func launch() throws -> MobileNotificationRegistration {
                let registration = MobileNotificationRegistration(
                    store: store, environment: .sandbox, requestToken: {},
                    register: { _, _, _ in registrations += 1; return registrations == 1 },
                    remove: { _, _ in }, subscribe: { _, _, topic in topics.append("on:\(topic)") },
                    unsubscribe: { _, _, topic in
                        topics.append("off:\(topic)")
                        if fails { throw URLError(.cannotConnectToHost) }
                    })
                try registration.select(apis: [ChannelAPI(serverURL: "https://fixture.example")])
                registration.update(enabled: true, requests: true, completions: false)
                registration.receivedToken(Data([1]))
                return registration
            }
            let first = try launch()
            await first.waitUntilIdle()
            #expect((first.error != nil) == failedWrite)
            topics = []
            fails = false
            let relaunched = try launch()
            await relaunched.waitUntilIdle()
            #expect(registrations == 2)
            #expect(relaunched.current == first.current)
            #expect(relaunched.isReady && relaunched.error == nil)
            #expect(topics == ["on:requests", "off:completions"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func eachServerRegistersOnItsOwnAndARemovedOneUnregistersAfterItsWriteWithoutAcceptingIt() async throws {
        try await withRegistrationStore { store in
            var events: [String] = []
            var created: [String] = []
            var held: CheckedContinuation<Void, Never>?
            var began: (() -> Void)?
            let registration = MobileNotificationRegistration(
                store: store, environment: .sandbox, requestToken: {},
                register: { api, _, _ in
                    events.append("register:\(api.baseURL.host ?? "")")
                    if api.baseURL.host == "offline.example", held == nil {
                        await withCheckedContinuation { continuation in
                            held = continuation
                            began?()
                        }
                    }
                    return true
                },
                remove: { api, _ in events.append("delete:\(api.baseURL.host ?? "")") },
                subscribe: { _, _, _ in }, unsubscribe: { _, _, _ in })
            registration.onCreated = { created.append($0.serverURL) }
            let offline = try ChannelAPI(serverURL: "https://offline.example")
            let online = try ChannelAPI(serverURL: "https://online.example")
            try registration.select(apis: [offline, online])
            let offlineID = try #require(registration.current.first?.registrationID)
            let onlineID = try #require(registration.current.last?.registrationID)
            registration.update(enabled: true, requests: true, completions: true)
            await withCheckedContinuation { continuation in
                began = { continuation.resume() }
                registration.receivedToken(Data([1]))
            }
            // The held server never holds up the other.
            for await ready in Observations({ registration.ready }) where ready.contains(onlineID) { break }
            #expect(created == ["https://online.example"])

            try registration.select(apis: [online])
            #expect(registration.current.map(\.registrationID) == [onlineID])
            #expect(registration.ready == [onlineID])
            #expect(!events.contains("delete:offline.example"))
            try #require(held).resume()
            await registration.waitUntilIdle()
            #expect(events.last == "delete:offline.example")
            #expect(events.filter { $0 == "register:online.example" }.count == 1)
            #expect(created == ["https://online.example"])
            #expect(registration.ready == [onlineID])

            try registration.select(apis: [offline, online])
            #expect(registration.current.first?.registrationID != offlineID)
            await registration.waitUntilIdle()
            #expect(registration.ready == Set(registration.current.map(\.registrationID)))
            #expect(created == ["https://online.example", "https://offline.example"])
        }
    }

    @Test func aFailedRegistrationStaysVisibleAndRetriesOnlyOnAnExplicitAttempt() async throws {
        try await withRegistrationStore { store in
            var inputs: [PushRegistration] = []
            let failure = NSError(domain: "MobileShellPushTests", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Registration unavailable"])
            let registration = MobileNotificationRegistration(
                store: store, environment: .sandbox, requestToken: {},
                register: { _, _, input in
                    inputs.append(input)
                    if inputs.count == 1 { throw failure }
                    return true
                }, remove: { _, _ in }, subscribe: { _, _, _ in }, unsubscribe: { _, _, _ in })
            try registration.select(apis: [ChannelAPI(serverURL: "https://first.example")])
            registration.update(enabled: true, requests: true, completions: true)
            registration.receivedToken(Data([1]))
            await registration.waitUntilIdle()
            #expect(registration.error == "Registration unavailable")
            #expect(!registration.isReady)
            registration.update(enabled: true, requests: true, completions: true)
            registration.receivedToken(Data([1]))
            await registration.waitUntilIdle()
            #expect(inputs.count == 1)
            #expect(registration.error == "Registration unavailable")
            registration.retry()
            await registration.waitUntilIdle()
            #expect(inputs.count == 2)
            #expect(inputs[0] == inputs[1])
            #expect(registration.error == nil)
            #expect(registration.isReady)
        }
    }

    @Test func aTokenFailureDoesNotRepeatAnUnchangedRequestUntilTryAgain() async throws {
        try await withRegistrationStore { store in
            var requests = 0
            let registration = MobileNotificationRegistration(
                store: store, environment: .sandbox, requestToken: { requests += 1 },
                register: { _, _, _ in false }, remove: { _, _ in }, subscribe: { _, _, _ in }, unsubscribe: { _, _, _ in })
            try registration.select(apis: [ChannelAPI(serverURL: "https://first.example")])
            registration.update(enabled: true, requests: true, completions: true)
            registration.failedToReceiveToken("Token unavailable")
            registration.update(enabled: true, requests: true, completions: true)
            #expect(requests == 1)
            #expect(registration.error == "Token unavailable")
            registration.retry()
            #expect(requests == 2)
            #expect(registration.error == nil)
        }
    }

    @Test(arguments: ["registration", "subscribe", "unsubscribe"])
    func activationRetriesAFailedPushApplyButLeavesSuccessfulSubscriptionsAlone(failedStep: String) async throws {
        var fails = true
        var registrations = 0
        var topics: [String] = []
        try await withNotifications(register: { _, _, _ in
            registrations += 1
            if fails, failedStep == "registration" { throw URLError(.cannotConnectToHost) }
            return false
        }, subscribe: { _, _, topic in
            topics.append("on:\(topic)")
            if fails, failedStep == "subscribe" { throw URLError(.cannotConnectToHost) }
        }, unsubscribe: { _, _, topic in
            topics.append("off:\(topic)")
            if fails, failedStep == "unsubscribe" { throw URLError(.cannotConnectToHost) }
        }) { defaults, registration, notifications in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession(), notifications: notifications)
            defer { model.setScenePhase(.background) }
            await notifications.enable()
            registration.receivedToken(Data([1]))
            await registration.waitUntilIdle()
            #expect(registrations == 1)
            #expect(notifications.registrationError != nil)
            topics = []
            fails = false
            model.setScenePhase(.active)
            await registration.waitUntilIdle()
            #expect(registrations == 2)
            #expect(topics == ["on:requests", "off:completions"])
            #expect(notifications.registrationError == nil)
            #expect(notifications.isReady(notifications.registrations.first))
            model.setScenePhase(.active)
            model.setScenePhase(.background)
            model.setScenePhase(.active)
            await registration.waitUntilIdle()
            #expect(registrations == 2)
            #expect(topics == ["on:requests", "off:completions"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func theIconBadgeUsesFreshWidgetWaitingCountsWithoutWaitingForAuthorization() async throws {
        let host = "\(UUID().uuidString.lowercased()).badge.test"
        let otherHost = "other-\(host)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BadgeFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            BadgeFixtureProtocol.responses.withLock { $0[host] = nil; $0[otherHost] = nil }
        }
        let channels = (0..<4).map { index in
            Channel(id: "\(index)", name: "Channel \(index)", model: .init(provider: "test", name: "test"),
                    latestSequence: 20, seenThrough: index == 0 ? 20 : 0,
                    completedSequence: index == 2 ? 20 : nil, requestSequence: index < 2 ? 12 : nil,
                    updatedAt: "2026-10-28T12:00:00Z")
        }
        func serve(_ channels: [Channel], status: Int = 200, on server: String? = nil) throws {
            let catalog = ChannelCatalog(
                lead: .init(name: "Lead", role: "Coordinator", avatar: .init(mark: "M4 12H20", color: "#123456")),
                channels: channels)
            let data = try JSONEncoder().encode(catalog)
            BadgeFixtureProtocol.responses.withLock { $0[server ?? host] = .init(status: status, data: data) }
        }
        let badges = BadgeRecorder()
        var authorization: CheckedContinuation<UNAuthorizationStatus, Never>?
        var beganAuthorization: (() -> Void)?
        try await withNotifications(enabled: true, readAuthorization: {
            await withCheckedContinuation { continuation in
                authorization = continuation
                beganAuthorization?()
            }
        }, setBadgeCount: { badges.counts.append($0) }) { defaults, _, notifications in
            let model = AppModel(arguments: ["--server", "https://\(host)"], environment: [:],
                                 defaults: defaults, session: session, notifications: notifications)
            let startup = Task { await model.startIntegrations() }
            defer {
                authorization?.resume(returning: .authorized)
                startup.cancel()
            }
            await withCheckedContinuation { continuation in
                if authorization != nil { continuation.resume() }
                else { beganAuthorization = { continuation.resume() } }
            }
            #expect(badges.counts.isEmpty)
            let catalog = try #require(model.catalog)
            try serve(channels)
            await catalog.refresh()
            await badges.waitForCalls(1)
            #expect(badges.counts == [2])
            #expect(!notifications.hasLoadedAuthorization)

            model.cover = .settings
            try serve(channels, status: 503)
            await catalog.refresh()
            #expect(catalog.phase.message != nil)
            try serve(channels)
            await catalog.refresh()
            await badges.waitForCalls(2)
            #expect(badges.counts == [2, 2])

            try serve(channels.map { channel in
                var answered = channel
                answered.requestSequence = nil
                return answered
            })
            await catalog.refresh()
            await badges.waitForCalls(3)
            #expect(badges.counts == [2, 2, 0])

            try model.changeAddress(of: #require(model.catalog), to: "https://other.example")
            model.cover = nil
            try model.changeAddress(of: #require(model.catalog), to: "https://\(host)")
            try serve([channels[0]])
            await model.catalog?.refresh()
            await badges.waitForCalls(4)
            #expect(badges.counts == [2, 2, 0, 1])

            try serve(channels, on: otherHost)
            let other = try model.addServer("https://\(otherHost)")
            await other.refresh()
            await badges.waitForCalls(5)
            #expect(badges.counts == [2, 2, 0, 1, 3])
            model.removeServer(try #require(model.catalog))
            await badges.waitForCalls(6)
            #expect(badges.counts == [2, 2, 0, 1, 3, 2])
            authorization?.resume(returning: .authorized)
            authorization = nil
            await startup.value
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func badgeWritesStayOrderedAndTheLatestCountOrOptOutWinsEvenAfterAFailure(optOut: Bool) async throws {
        let badges = BadgeRecorder()
        var held: CheckedContinuation<Void, Never>?
        var began: (() -> Void)?
        var inFlight = 0
        var maximumInFlight = 0
        try await withNotifications(enabled: true, setBadgeCount: { count in
            inFlight += 1
            maximumInFlight = max(maximumInFlight, inFlight)
            defer { inFlight -= 1 }
            if count == 4 {
                await withCheckedContinuation {
                    held = $0
                    began?()
                }
                throw URLError(.cannotConnectToHost)
            }
            badges.counts.append(count)
        }) { _, _, notifications in
            await withCheckedContinuation { continuation in
                began = { continuation.resume() }
                notifications.updateBadge(4)
            }
            notifications.updateBadge(3)
            if optOut { notifications.disable() }
            if !optOut { notifications.updateBadge(0) }
            #expect(badges.counts.isEmpty)
            try #require(held).resume()
            await badges.waitForCalls(1)
            #expect(badges.counts == [0])
            #expect(maximumInFlight == 1)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func notificationOptOutKeepsTheBadgeClearBeforeAuthorizationLoads(initiallyEnabled: Bool) async throws {
        let badges = BadgeRecorder()
        try await withNotifications(enabled: initiallyEnabled, setBadgeCount: { badges.counts.append($0) }) {
            defaults, _, notifications in
            notifications.updateBadge(2)
            await badges.waitForCalls(1)
            if initiallyEnabled {
                #expect(badges.counts == [2])
                notifications.disable()
                await badges.waitForCalls(2)
            }
            let cleared = initiallyEnabled ? [2, 0] : [0]
            #expect(badges.counts == cleared)
            #expect(!defaults.bool(forKey: "notificationsEnabled"))
            #expect(!notifications.hasLoadedAuthorization)

            notifications.updateBadge(7)
            await badges.waitForCalls(cleared.count + 1)
            #expect(badges.counts == cleared + [0])
            #expect(!notifications.hasLoadedAuthorization)
        }
    }

    @Test(arguments: [false, true])
    func notificationAndActivityRoutesRevealRequestsOnTheirOwnServerOnly(activityLink: Bool) async throws {
        try await withNotifications { defaults, registration, notifications in
            let id = try #require(registration.current.first?.registrationID)
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession(), notifications: notifications)
            let second = try model.addServer("https://second.example")
            try registration.select(apis: model.catalogs.map(\.api))
            let secondID = try #require(registration.current.last?.registrationID)
            @MainActor func open(_ kind: ChannelPushPayload.Kind, _ channel: String, _ sequence: Int,
                                 _ registrationID: String) async throws {
                if activityLink {
                    await model.openExternalURL(try #require(ChannelActivityLink(
                        channelID: channel, registrationID: registrationID,
                        sequence: kind == .request ? sequence : nil).url))
                } else {
                    await notifications.receive(
                        ChannelPushPayload(kind: kind, channelID: channel, sequence: sequence, registrationID: registrationID),
                        action: UNNotificationDefaultActionIdentifier, text: nil, handle: nil, identifier: kind.rawValue)
                }
            }
            try await open(.request, "first", 42, id)
            #expect(model.selectedChannelID == "first")
            #expect(model.interaction(for: "first").revealRequest?.sequence == 42)
            try await open(.completion, "second", 51, id)
            #expect(model.selectedChannelID == "second")
            #expect(model.interaction(for: "second").revealRequest == nil)
            try await open(.request, "first", 43, secondID)
            let elsewhere = try #require(second.target("first"))
            #expect(model.selection == elsewhere)
            #expect(model.interaction(for: elsewhere).revealRequest?.sequence == 43)
            try await open(.request, "first", 88, "old")
            #expect(model.selection == elsewhere)
            #expect(model.navigationNotice == (activityLink ? "This channel isn't available." : nil))
            #expect(model.serverURL == "https://fixture.example")
        }
    }

    @Test func aReplyOrChoiceSavesForItsOwnServerAndClearsOnlyThatNotification() async throws {
        var removed: [String] = []
        try await withNotifications(removeDelivered: { removed += $0 }) { _, registration, notifications in
            let apis = try ["https://fixture.example", "https://second.example"].map { try ChannelAPI(serverURL: $0) }
            notifications.configure(apis: apis)
            try registration.select(apis: apis)
            let id = try #require(registration.current.first?.registrationID)
            let secondID = try #require(registration.current.last?.registrationID)
            let current = try #require(URL(string: "https://fixture.example"))
            let second = try #require(URL(string: "https://second.example"))
            let earlier = try #require(URL(string: "https://earlier.example"))
            var saved: [ChannelNotifications.Reply] = []
            notifications.onReply = { saved.append($0) }

            await notifications.receive(
                ChannelPushPayload(kind: .request, channelID: "first", sequence: 42, registrationID: id),
                action: ChannelNotificationCategory.reply, text: "  Keep the library by the desks\n",
                handle: "lead", identifier: "request")
            await notifications.receive(
                ChannelPushPayload(kind: .completion, channelID: "second", sequence: 7, registrationID: "old"),
                action: "reply-choice.1", text: nil, handle: "lead", replies: ["Yes", "No"],
                server: earlier.absoluteString, identifier: "earlier")
            await notifications.receive(
                ChannelPushPayload(kind: .request, channelID: "first", sequence: 43, registrationID: "old"),
                action: ChannelNotificationCategory.reply, text: "Nowhere to go", handle: "lead", identifier: "unknown")
            await notifications.receive(
                ChannelPushPayload(kind: .request, channelID: "first", sequence: 44, registrationID: id),
                action: ChannelNotificationCategory.reply, text: "  ", handle: "lead", identifier: "empty")
            await notifications.receive(
                ChannelPushPayload(kind: .request, channelID: "first", sequence: 45, registrationID: secondID),
                action: ChannelNotificationCategory.reply, text: "Ship it", handle: nil, identifier: "second")

            #expect(saved == [
                .init(content: "@lead Keep the library by the desks", channelID: "first", server: current, request: 42),
                .init(content: "No", channelID: "second", server: earlier, request: nil),
                .init(content: "Ship it", channelID: "first", server: second, request: 45)
            ])
            #expect(removed == ["request", "earlier", "second"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func followingReceivesItsReadyRegistrationWhileAuthorizationIsStillPending() async throws {
        var authorization: CheckedContinuation<UNAuthorizationStatus, Never>?
        var beganAuthorization: (() -> Void)?
        try await withNotifications(readAuthorization: {
            await withCheckedContinuation { continuation in
                authorization = continuation
                beganAuthorization?()
            }
        }) { defaults, registration, notifications in
            let following = ChannelFollowController(
                client: .init(activities: { [] }, request: { _, _ in throw CocoaError(.featureUnsupported) }))
            defer { following.shutdown() }
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession(),
                                 notifications: notifications, following: following)
            let store = try #require(model.catalog?.channel(id: "first"))
            _ = try store.apply(.init(type: "snapshot", state: .init(
                revision: 1,
                channel: .init(id: store.id, name: "Workshop", model: .init(provider: "test", name: "test"),
                               tasks: [.init(id: "root", title: "Work")], updatedAt: "2026-10-28T00:00:00Z"),
                lead: .init(id: store.id, name: "Lead")
            )))
            registration.receivedToken(Data([1]))
            await registration.waitUntilIdle()
            #expect(notifications.isReady(notifications.registrations.first))
            let startup = Task { await model.startIntegrations() }
            await withCheckedContinuation { continuation in
                if authorization != nil { continuation.resume() }
                else { beganAuthorization = { continuation.resume() } }
            }
            #expect(!notifications.hasLoadedAuthorization)
            #expect(!notifications.isEnabled)
            #expect(following.state(for: store) == .available)
            authorization?.resume(returning: .authorized)
            await startup.value
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func followingObservesTheSelectedCatalogAndRegistrationIndependentlyOfAlertOptIn() async throws {
        var response: CheckedContinuation<Bool, Never>?
        var began: (() -> Void)?
        try await withNotifications(register: { _, _, _ in
            if response == nil {
                return await withCheckedContinuation { continuation in
                    response = continuation
                    began?()
                }
            }
            return false
        }) { defaults, registration, notifications in
            let firstAPI = try ChannelAPI(serverURL: "https://fixture.example")
            let following = ChannelFollowController(
                client: .init(activities: { [] }, request: { _, _ in throw CocoaError(.featureUnsupported) }))
            defer { following.shutdown() }
            let model = AppModel(arguments: ["--server", firstAPI.baseURL.absoluteString], environment: [:],
                                 defaults: defaults, session: fixtureSession(),
                                 notifications: notifications, following: following)
            @MainActor func prepare(_ store: ChannelStore) throws {
                _ = try store.apply(.init(type: "snapshot", state: .init(
                    revision: 1,
                    channel: .init(id: store.id, name: "Workshop", model: .init(provider: "test", name: "test"),
                                   tasks: [.init(id: "root", title: "Work")], updatedAt: "2026-10-27T00:00:00Z"),
                    lead: .init(id: store.id, name: "Lead")
                )))
            }
            @MainActor func waitFor(_ state: ChannelFollowAction.Status, for store: ChannelStore) async {
                for await current in Observations({ following.state(for: store) }) {
                    if current == state { return }
                }
            }
            let first = try #require(model.catalog?.channel(id: "first"))
            try prepare(first)
            #expect(following.state(for: first) == .unavailable(nil))
            await model.startIntegrations()
            await withCheckedContinuation { continuation in
                began = { continuation.resume() }
                registration.receivedToken(Data([1]))
            }
            #expect(notifications.registrations == registration.current)
            #expect(!notifications.isReady(notifications.registrations.first))
            #expect(following.state(for: first) == .unavailable(nil))
            #expect(!notifications.isEnabled)
            try #require(response).resume(returning: false)
            await registration.waitUntilIdle()
            await waitFor(.available, for: first)
            #expect(notifications.isReady(notifications.registrations.first))

            try model.changeAddress(of: #require(model.catalog), to: "https://second.example")
            let secondAPI = try #require(model.api)
            try registration.select(apis: [secondAPI])
            let second = try #require(model.catalog?.channel(id: "first"))
            try prepare(second)
            await waitFor(.available, for: second)
            #expect(following.state(for: first) == .unavailable(nil))

            try registration.select(apis: [firstAPI])
            await waitFor(.unavailable(nil), for: second)
            try registration.select(apis: [secondAPI])
            await waitFor(.available, for: second)
            #expect(!notifications.isEnabled)
        }
    }

    @Test func presentationKeepsTheVisibleChannelQuietAndCompletionsInNotificationCenter() async throws {
        try await withNotifications { _, registration, notifications in
            await notifications.enable()
            await notifications.update(channels: [:], activeChannel: ChannelTarget(serverURL: "https://fixture.example", channelID: "first"),
                                      withdrawing: [])
            let id = try #require(registration.current.first?.registrationID)
            let visible = ChannelPushPayload(kind: .request, channelID: "first", sequence: 42, registrationID: id)
            let other = ChannelPushPayload(kind: .request, channelID: "second", sequence: 45, registrationID: id)
            #expect(notifications.presentation(for: visible, category: ChannelNotificationCategory.request).isEmpty)
            #expect(notifications.presentation(for: other, category: ChannelNotificationCategory.request)
                    == [.banner, .list, .sound])
            #expect(notifications.presentation(for: other, category: ChannelNotificationCategory.completion) == [.list])
            notifications.disable()
            #expect(notifications.presentation(for: other, category: ChannelNotificationCategory.request).isEmpty)
        }
    }

    @Test(arguments: [0, 1, 2])
    func foregroundCountPushesApplyOnlyTheBadgeAndRespectOptOut(count: Int) async throws {
        try await withNotifications { _, _, notifications in
            await notifications.enable()
            await notifications.update(channels: [:], activeChannel: ChannelTarget(serverURL: "https://fixture.example", channelID: "first"),
                                      withdrawing: [])
            #expect(notifications.presentation(for: nil, category: "", badge: NSNumber(value: count)) == [.badge])
            #expect(!notifications.presentation(for: nil, category: "").contains(.badge))
            notifications.disable()
            #expect(notifications.presentation(for: nil, category: "", badge: NSNumber(value: count)).isEmpty)
        }
    }

    @Test func notificationDelegateUsesSystemSelectorsAndCompletesOnMainThreadAfterSuspending() async {
        await withDefaults { defaults in
            let notifications = ChannelNotifications(defaults: defaults)
            #expect(notifications.responds(to: #selector(
                ChannelNotifications.userNotificationCenter(_:willPresent:withCompletionHandler:))))
            #expect(notifications.responds(to: #selector(
                ChannelNotifications.userNotificationCenter(_:didReceive:withCompletionHandler:))))
            let result = await Task.detached {
                await withCheckedContinuation { continuation in
                    ChannelNotifications.completeOnMainActor({
                        await Task.yield()
                        return UNNotificationPresentationOptions.list
                    }, completionHandler: { options in
                        continuation.resume(returning: (options, Thread.isMainThread))
                    })
                }
            }.value
            #expect(result.0 == [.list])
            #expect(result.1)
        }
    }

    @Test func withdrawalRemovesAnsweredRequestsSeenCompletionsAndTheOpenChannelsAlerts() {
        let channels = [
            Channel(id: "first", name: "First", model: .init(provider: "test", name: "test"),
                    seenThrough: 30, completedSequence: 30, requestSequence: 40, updatedAt: ""),
            Channel(id: "open", name: "Open", model: .init(provider: "test", name: "test"), updatedAt: "")
        ]
        let records: [ChannelNotification.Delivered] = [
            .init(identifier: "answered", payload: .init(kind: .request, channelID: "first", sequence: 20, registrationID: "now")),
            .init(identifier: "waiting", payload: .init(kind: .request, channelID: "first", sequence: 40, registrationID: "now")),
            .init(identifier: "seen", payload: .init(kind: .completion, channelID: "first", sequence: 30, registrationID: "now")),
            .init(identifier: "unseen", payload: .init(kind: .completion, channelID: "first", sequence: 50, registrationID: "now")),
            .init(identifier: "open", payload: .init(kind: .request, channelID: "open", sequence: 1, registrationID: "now")),
            .init(identifier: "deleted", payload: .init(kind: .request, channelID: "gone", sequence: 1, registrationID: "now")),
            .init(identifier: "foreign", payload: .init(kind: .request, channelID: "first", sequence: 1, registrationID: "old")),
        ]
        #expect(ChannelNotification.Delivered.stale(records, channels: channels, scope: "now", activeChannelID: "open")
                == ["answered", "seen", "open", "deleted"])
    }

    @Test func enablingNotificationsRequestsPermissionOnceAndKeepsCategoryChoicesWhenTurnedOff() async {
        await withDefaults { defaults in
            var status = UNAuthorizationStatus.notDetermined
            var prompts = 0
            let notifications = ChannelNotifications(defaults: defaults, readAuthorization: { status },
                                                      requestAuthorization: {
                prompts += 1
                status = .authorized
                return true
            })
            #expect(!notifications.isEnabled)
            #expect(notifications.requests)
            #expect(!notifications.completions)
            #expect(!notifications.hasLoadedAuthorization)
            await notifications.enable()
            #expect(prompts == 1)
            #expect(notifications.authorization == .authorized)
            #expect(notifications.isEnabled)
            #expect(defaults.bool(forKey: "notificationsEnabled"))
            notifications.requests = false
            notifications.completions = true
            notifications.disable()
            #expect(!notifications.isEnabled)
            #expect(!notifications.requests)
            #expect(notifications.completions)
            await notifications.enable()
            #expect(prompts == 1)
            #expect(notifications.isEnabled)
            #expect(!notifications.requests)
            let restored = ChannelNotifications(defaults: defaults, readAuthorization: { status })
            await restored.refreshAuthorization()
            #expect(restored.isEnabled)
            #expect(!restored.requests)
            #expect(restored.completions)
        }
    }

    @Test(arguments: [false, true])
    func savedNotificationChoicesOverrideTheRequestOnlyDefaults(completions: Bool) async {
        await withDefaults { defaults in
            defaults.set(!completions, forKey: "requestNotifications")
            defaults.set(completions, forKey: "completionNotifications")
            let notifications = ChannelNotifications(defaults: defaults)
            #expect(notifications.requests == !completions)
            #expect(notifications.completions == completions)
        }
    }

    @Test func permissionRechecksRequireExplicitEnableOrAnOpenSettingsRequest() async {
        await withDefaults { defaults in
            defaults.set(true, forKey: "notificationsEnabled")
            var status = UNAuthorizationStatus.authorized
            var prompts = 0
            var opened = 0
            let notifications = ChannelNotifications(defaults: defaults, readAuthorization: { status },
                                                      requestAuthorization: {
                prompts += 1
                return false
            }, openSettings: { opened += 1; return true })
            await notifications.refreshAuthorization()
            #expect(notifications.isEnabled)
            status = .denied
            await notifications.refreshAuthorization()
            #expect(notifications.authorization == .denied)
            #expect(!notifications.isEnabled)
            #expect(!defaults.bool(forKey: "notificationsEnabled"))
            await notifications.enable()
            #expect(prompts == 0)
            status = .authorized
            await notifications.refreshAuthorization()
            #expect(!notifications.isEnabled)
            await notifications.enable()
            #expect(notifications.isEnabled)
            #expect(prompts == 0)
            status = .denied
            await notifications.refreshAuthorization()
            await notifications.openSystemSettings()
            #expect(opened == 1)
            #expect(!notifications.isEnabled)
            status = .authorized
            await notifications.refreshAuthorization()
            #expect(notifications.isEnabled)
            notifications.disable()
            await notifications.refreshAuthorization()
            #expect(!notifications.isEnabled)
        }
    }

    @Test func aPermissionFailureRemainsExplicitAndNeverEnablesNotifications() async {
        await withDefaults { defaults in
            let failure = NSError(domain: "MobileShellNotificationTests", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Permission service unavailable"])
            let notifications = ChannelNotifications(defaults: defaults, readAuthorization: { .notDetermined },
                                                      requestAuthorization: { throw failure })
            await notifications.enable()
            #expect(!notifications.isEnabling)
            #expect(!notifications.isEnabled)
            #expect(notifications.error == failure.localizedDescription)
            #expect(notifications.authorization == .notDetermined)
        }
    }

    @Test func handoffOpensInTheReceivingCatalogWithoutRestoringAnotherChannelOrReplacingItsDraft() async throws {
        try await withDefaults { defaults in
            let server = "https://handoff-\(UUID().uuidString).example"
            let model = AppModel(arguments: ["--server", server], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            defaults.set([model.serverURL: "second"], forKey: "lastChannelByServer")
            let store = try #require(model.catalog?.channel(id: "first"))
            let draft = model.composerSession(for: store).draft
            draft.text = "This device's draft"
            defer { draft.text = "" }
            let generation = model.beginHandoffNavigation()
            await model.catalog?.refresh()
            model.reconcileSelection()
            #expect(model.selectedChannelID == nil)
            let activity = NSUserActivity(activityType: ChannelHandoff.activityType)
            activity.userInfo = [
                ChannelHandoff.channelIDKey: "first", "draft": "Another device's draft",
                "serverURL": "https://another.example"
            ]
            let navigation = ChannelHandoffNavigation()
            await navigation.continueActivity(activity, catalogs: { model.catalogs }) { _, id in
                model.openHandoffChannel(model.target(id)!, generation: generation)
            }
            #expect(model.selectedStore === store)
            #expect(model.serverURL == server)
            #expect(draft.text == "This device's draft")
            model.selectedChannelID = nil
            model.reconcileSelection()
            #expect(model.selectedChannelID == nil)
            #expect(model.composerSession(for: store).draft === draft)
        }
    }

    @Test func newerLocalNavigationOrServerSelectionInvalidatesThePhoneHandoffDestination() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            let generation = model.beginHandoffNavigation()
            model.selectedChannelID = "second"
            model.openHandoffChannel(model.target("first")!, generation: generation)
            #expect(model.selectedChannelID == "second")
            let beforeSwitch = model.beginHandoffNavigation()
            try model.changeAddress(of: #require(model.catalog), to: "https://another.example")
            model.openHandoffChannel(model.target("first")!, generation: beforeSwitch)
            #expect(model.selectedChannelID == nil)
            #expect(model.serverURL == "https://another.example")
        }
    }

    @Test func widgetRequestRoutingPreparesTheOriginalRevealBeforeOpeningAndKeepsTheDraft() async throws {
        try await withDefaults { defaults in
            let server = "https://widget-open-\(UUID().uuidString).example"
            let model = AppModel(arguments: ["--server", server], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            let store = try #require(model.catalog?.channel(id: "first"))
            let draft = model.composerSession(for: store).draft
            draft.text = "Keep this local draft"
            defer { draft.text = "" }
            defaults.set([model.serverURL: "second"], forKey: "lastChannelByServer")
            let request = NeedsYouRequestLink(serverURL: model.serverURL, channelID: "first", sequence: 42)
            await model.openExternalURL(try #require(request.url))
            #expect(model.selectedStore === store)
            #expect(model.selectedChannelID == "first")
            #expect(model.interaction(for: "first").revealRequest?.sequence == 42)
            #expect(model.interaction(for: "first").messageView == .all)
            #expect(!model.isResolvingNavigation)
            #expect(draft.text == "Keep this local draft")
        }
    }

    @Test func widgetReplyRequestsComposerFocusAndTheMainLinkReturnsToChannels() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            let interaction = model.interaction(for: "first")
            let previousFocus = interaction.composerFocusRequest
            let request = NeedsYouRequestLink(serverURL: model.serverURL, channelID: "first", sequence: 42)
            await model.openExternalURL(try #require(request.replyURL))
            #expect(model.selectedChannelID == "first")
            #expect(interaction.composerFocusRequest != previousFocus)
            #expect(interaction.revealRequest?.sequence == 42)
            await model.openExternalURL(NeedsYouSnapshot.mainURL)
            #expect(model.selectedChannelID == nil)
            model.reconcileSelection()
            #expect(model.selectedChannelID == nil)
        }
    }

    @Test func aNotificationWidgetOrHandoffOpenClosesWhateverCoversTheApp() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            model.cover = .screens
            let request = NeedsYouRequestLink(serverURL: model.serverURL, channelID: "first", sequence: 42)
            await model.openExternalURL(try #require(request.url))
            #expect(model.cover == nil)
            #expect(model.selectedChannelID == "first")
            model.cover = .screen("window-1", serverURL: model.serverURL)
            await model.openChannel(id: "second", sequence: 7, on: model.serverURL)
            #expect(model.cover == nil)
            #expect(model.selectedChannelID == "second")
            model.cover = .settings
            _ = model.beginHandoffNavigation()
            #expect(model.cover == nil)
        }
    }

    @Test func aScreenHoldsOverviewInPlaceUntilItCloses() {
        let overview = Overview()
        overview.isHeld = true
        overview.move(to: .inspector)
        #expect(overview.placement == .sheet)
        overview.isHeld = false
        #expect(overview.placement == .inspector)
    }

    @Test func aWidgetRequestOpensOnItsOwnServerAndNeverAnUnlistedOne() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            let second = try model.addServer("https://second.example")
            let listed = NeedsYouRequestLink(serverURL: "https://second.example", channelID: "first", sequence: 41)
            await model.openExternalURL(try #require(listed.url))
            let target = try #require(second.target("first"))
            #expect(model.selection == target)
            #expect(model.interaction(for: target).revealRequest?.sequence == 41)
            let request = NeedsYouRequestLink(serverURL: "https://other.example", channelID: "first", sequence: 42)
            await model.openExternalURL(try #require(request.url))
            #expect(model.serverURL == "https://fixture.example")
            #expect(model.selection == target)
            #expect(model.navigationNotice == "This channel isn't available.")
        }
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
            #expect(defaults.string(forKey: "serverURL") == "https://saved.example/prefix")
            let saved = AppModel(arguments: [], environment: [:], defaults: defaults)
            #expect(saved.serverURL == "https://saved.example/prefix")
            #expect(ChannelCatalogStore.Saved.load(from: defaults) == [.init(url: "https://saved.example/prefix")])
        }
    }

    @Test func anInvalidSavedServerIsDroppedSoWelcomeAsksForOne() async {
        await withDefaults { defaults in
            defaults.set("not-a-server", forKey: "serverURL")
            let model = AppModel(arguments: [], environment: [:], defaults: defaults)
            #expect(model.catalog == nil)
            #expect(model.configurationError == nil)
            #expect(model.serverURL.isEmpty)
            #expect(defaults.string(forKey: "serverURL") == nil)
        }
    }

    @Test func settingsKeepsEveryServerInItsOrderAndTheLastOneStays() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: [], environment: [:], defaults: defaults, session: fixtureSession())
            let first = try model.addServer("https://first.example")
            let second = try model.addServer("https://second.example")
            #expect(try model.addServer("https://second.example") === second)
            #expect(try model.changeAddress(of: first, to: "https://second.example") === second)
            model.rename(second, to: "  Work ")
            model.moveServers(fromOffsets: [1], toOffset: 0)
            #expect(model.catalog === second)
            #expect(model.serverURL == "https://second.example")
            model.removeServer(first)
            model.removeServer(second)
            #expect(model.catalogs.count == 1 && model.catalog === second)
            let relaunched = AppModel(arguments: [], environment: [:], defaults: defaults)
            #expect(relaunched.catalogs.map(\.saved) == [.init(url: "https://second.example", name: "Work")])
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

    @Test func firstLaunchHasNoServerOrChannelLinks() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: [], environment: [:], defaults: defaults)
            #expect(model.serverURL.isEmpty)
            #expect(model.catalog == nil)
            #expect(model.configurationError == nil)
            #expect(defaults.string(forKey: "serverURL") == nil)
            let first = try #require(ChannelTarget(serverURL: "https://fixture.example", channelID: "first"))
            #expect(model.channelURL(first) == nil)
            try model.addServer("https://fixture.example")
            #expect(model.channelURL(first) != nil)
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

    @Test(arguments: [ChannelCatalogPhase.connecting, .connected])
    func nonFailureCatalogStatesReserveNoFooterSpace(phase: ChannelCatalogPhase) {
        let host = UIHostingController(rootView: ChannelSidebarFailure(
            footer: SidebarFooter(phase: phase, isLoaded: true), error: nil, canRetry: true,
            retry: {}, openSettings: {}
        ))
        host.loadViewIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        #expect(size.height == 0)
    }

    #if DEBUG
    @Test(arguments: [true, false], [false, true])
    func keptRowsShowTheReconnectingPillAndOtherFailuresKeepTheirErrorRetryAndUnfoldedSettings(
        isLoaded: Bool, showsSettings: Bool
    ) throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let footer = SidebarFooter(phase: .failed(URLError(.timedOut)), isLoaded: isLoaded)
        var retries = 0
        let host = UIHostingController(rootView: ChannelSidebarFailure(
            footer: footer, error: "The server is unavailable.", canRetry: true,
            retry: { retries += 1 }, openSettings: {}, showsSettingsButton: showsSettings
        ))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let elements = MobileAutomationTree(windows: [window]).elements
        let labels = elements.map(\.label)
        #expect(!labels.contains("Server connection") && !labels.contains("Server Settings"), "\(labels)")
        if isLoaded {
            let pill = try #require(elements.first { $0.label.contains("Reconnecting to server") }, "\(labels)")
            #expect(pill.label.contains("Channels may be out of date") && pill.traits.contains(.button))
            #expect(pill.object.accessibilityHint == "The server is unavailable.")
            #expect(!labels.contains("Retry") && !labels.contains("Settings"), "\(labels)")
            #expect(pill.activate() && retries == 1)
        } else {
            #expect(labels.contains(try #require(footer.heading)), "\(labels)")
            #expect(labels.contains("The server is unavailable."), "\(labels)")
            #expect(labels.contains("Retry"), "\(labels)")
            #expect(labels.contains("Settings") == showsSettings, "\(labels)")
        }
    }
    #endif

    @Test(arguments: [240.0, 386.0])
    func channelRowsUseTwoLinesWithoutAnEmptyWorkingLine(width: Double) {
        let channel = Channel(id: "layout", name: "Workshop", directory: "/Projects/Workshop",
                              model: .init(provider: "test", name: "test"), updatedAt: "2026-10-25T12:00:00Z")
        let agents = (0..<4).map { index in
            ChannelAgent.lead(id: "agent-\(index)", profile: .init(
                name: "Agent \(index)", role: "Coordinator", avatar: .init(mark: "M4 12H20", color: "#123456")
            ))
        }
        func height(working: [ChannelAgent], attention: Channel.Attention?) -> CGFloat {
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
        // A quiet row keeps the faces' line, so the row holds still as agents start and stop.
        #expect(height(working: [], attention: nil) == workingHeight)
        #expect(height(working: agents, attention: nil) == workingHeight)
        #expect(height(working: agents, attention: .waiting) == workingHeight)
    }

    @Test(arguments: [false, true])
    func aReaderWaitsForActualCompactOverviewDismissalNotJustTheClosedIntent(imageReader: Bool) {
        let overview = Overview()
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
            let gallery = model.gallery(for: store)
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
            #expect(model.gallery(for: store) === gallery)
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
            let gallery = model.gallery(for: store)
            gallery.open(images: [.init(name: "image.png", url: "/image.png")], at: 0,
                         source: .init(messageID: "image", sender: "Lead", timestamp: "2026-10-25T12:00:00Z"),
                         api: store.api)
            interaction.isArtifactViewerPresented = true
            let replacement: ChannelStore
            if changingServer {
                try model.changeAddress(of: #require(model.catalog), to: "https://second.example")
                replacement = try #require(model.catalog?.channel(id: store.id))
            } else {
                replacement = ChannelStore(id: store.id, api: store.api)
            }
            #expect(model.artifactSession(for: replacement) !== artifacts)
            #expect(model.gallery(for: replacement) !== gallery)
            #expect(gallery.session == nil)
            #expect(!interaction.isArtifactViewerPresented)
        }
    }

    @Test func storesAndInteractionSurviveNavigationAndTheBackgroundStopsTheConnection() async throws {
        await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            model.selectedChannelID = "first"
            let store = model.selectedStore
            let interaction = model.interaction(for: "first")
            interaction.messageView = .yours
            interaction.reveal(sequence: 42)
            model.setScenePhase(.active)
            #expect(store?.isTrying == true)
            model.setScenePhase(.background)
            #expect(store?.isTrying == false)
            #expect(model.catalog?.isActive == false)
            model.selectedChannelID = "second"
            model.selectedChannelID = "first"
            #expect(model.selectedStore === store)
            #expect(model.interaction(for: "first") === interaction)
            #expect(interaction.messageView == .yours)
            #expect(interaction.revealRequest?.sequence == 42)
            #expect(model.selectedStore?.isTrying == false)
        }
    }

    @Test func briefInterruptionsKeepTheStreamAndOnlyTheBackgroundDropsIt() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            defer { model.setScenePhase(.background) }
            await model.refreshCatalog()
            let catalog = try #require(model.catalog)
            model.selectedChannelID = "first"
            let store = try #require(model.selectedStore)
            model.setScenePhase(.active)
            #expect(store.isTrying)
            #expect(model.canManageChannels)

            let interrupted = ChangeFlag()
            withObservationTracking {
                _ = store.phase
                _ = catalog.isActive
            } onChange: { interrupted.set() }
            model.setScenePhase(.inactive)
            #expect(!model.isActive)
            #expect(!model.canManageChannels)
            model.setScenePhase(.active)
            #expect(model.isActive)
            #expect(!interrupted.isSet)
            #expect(store.isTrying)
            #expect(catalog.isActive)

            model.setScenePhase(.inactive)
            model.setScenePhase(.background)
            #expect(interrupted.isSet)
            #expect(!store.isTrying)
            #expect(!catalog.isActive)
            model.setScenePhase(.inactive)
            #expect(store.isTrying)
            #expect(catalog.isActive)
            #expect(!model.isActive)
        }
    }

    @Test func managementOwnersResumeWithoutASelectedChannelOnlyInTheForeground() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            defer { model.setScenePhase(.background) }
            let store = try #require(model.catalog?.channel(id: "first"))
            model.hold(store)
            #expect(model.selectedChannelID == nil)
            #expect(!store.isTrying)
            model.setScenePhase(.inactive)
            #expect(store.isTrying)
            model.setScenePhase(.background)
            #expect(!store.isTrying)
            model.setScenePhase(.active)
            #expect(store.isTrying)
            model.selectedChannelID = store.id
            #expect(model.selectedStore === store)
            model.release(store)
            #expect(store.isTrying)
        }
    }

    @Test func creationAvailabilityUsesTheSameCatalogConnectionAsTheSidebar() async throws {
        await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            defer { model.setScenePhase(.background) }
            #expect(model.catalog?.phase == .connecting)
            #expect(!model.canCreateChannel)
            #expect(!model.canManageChannels)
            await model.refreshCatalog()
            #expect(model.catalog?.phase == .connected)
            #expect(!model.canCreateChannel)
            #expect(!model.canManageChannels)
            model.setScenePhase(.active)
            #expect(model.canCreateChannel)
            #expect(model.selectedChannelID == nil)
            #expect(model.canManageChannels)
            model.selectedChannelID = "second"
            #expect(model.canManageChannels)
            model.setScenePhase(.inactive)
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
            try model.changeAddress(of: #require(model.catalog), to: "https://second.example")
            #expect(model.selectedStore == nil)
            #expect(previousStore?.isTrying == false)
            #expect(model.interaction(for: "first") !== previousInteraction)
            #expect(defaults.dictionary(forKey: "lastChannelByServer")?["https://first.example"] as? String == "first")
            #expect(defaults.data(forKey: ChannelCatalogStore.Saved.key) == nil, "A launch server stays in the session.")
        }
    }

    @Test func anAddressAlreadyListedFindsThatServerAndLeavesTheFirstUntouched() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://first.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            let first = try #require(model.catalog)
            let second = try model.addServer("https://second.example/prefix")
            model.selectedChannelID = "second"
            model.visibleChannelID = "second"
            let store = model.selectedStore
            let interaction = model.interaction(for: "second")
            #expect(try model.changeAddress(of: first, to: "https://second.example/prefix") === second)
            #expect(model.catalogs.count == 2 && model.catalog === first && model.catalogs.last === second)
            #expect(model.serverURL == "https://first.example")
            #expect(model.selectedStore === store)
            #expect(model.visibleChannelID == "second")
            #expect(model.interaction(for: "second") === interaction)
        }
    }

    @Test func aSelectionKeepsItsServerThroughARelaunchAndAReorderAndLeavesWithIt() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: [], environment: [:], defaults: defaults, session: fixtureSession())
            try model.addServer("https://first.example")
            let second = try model.addServer("https://second.example")
            model.selection = second.target("second")
            let store = try #require(model.selectedStore)
            #expect(store.api.baseURL == second.api.baseURL)
            #expect(model.selectedServer == model.selection?.serverURL)

            let relaunched = AppModel(arguments: [], environment: [:], defaults: defaults, session: fixtureSession())
            await relaunched.refreshCatalog()
            #expect(relaunched.selection == second.target("second"))

            model.moveServers(fromOffsets: [1], toOffset: 0)
            #expect(model.catalog === second)
            #expect(model.selection == second.target("second"))
            #expect(model.selectedStore === store)
            model.removeServer(second)
            #expect(model.selection == nil)
            #expect(model.selectedStore == nil)
            #expect(model.selectedServer == model.serverURL)
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
                try model.changeAddress(of: #require(catalog), to: "file:///not-a-server")
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
                model.setScenePhase(.background)
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
            model.setScenePhase(.active)
            #expect(firstStore.isTrying)
            try model.changeAddress(of: #require(model.catalog), to: secondAddress)
            #expect(!firstStore.isTrying)
            #expect(model.selectedStore == nil)
            #expect(model.visibleChannelID == nil)
            #expect(model.serverURL == secondAddress)
            await model.refreshCatalog()
            #expect(model.selectedChannelID == nil)
            let secondStore = try #require(model.catalog?.channel(id: "first"))
            let secondDraft = model.composerSession(for: secondStore).draft
            drafts.append(secondDraft)
            #expect(secondDraft !== firstDraft)
            #expect(secondDraft.text.isEmpty)
            secondDraft.text = "Draft for the second server"
            model.selectedChannelID = "second"
            try model.changeAddress(of: #require(model.catalog), to: firstAddress)
            await model.refreshCatalog()
            #expect(model.selectedChannelID == "first")
            let restoredStore = try #require(model.selectedStore)
            #expect(model.composerSession(for: restoredStore).draft === firstDraft)
            #expect(firstDraft.text == "Draft for the first server")
            #expect(secondDraft.text == "Draft for the second server")
            #expect(defaults.dictionary(forKey: "lastChannelByServer")?[secondAddress] as? String == "second")
        }
    }

    @Test func theCardTestsOnlyAValidIdleAddressAndMarksOnlyItsOwnSuccess() async throws {
        let connection = ServerConnectionProbe(address: "http://127.0.0.1:3100/prefix", session: fixtureSession())
        let section = ServerConnectionSection(connection: connection, placeholder: "", footer: "",
                                              failure: .constant(nil))
        #expect(section.canTest)
        #expect(!section.isConnected)
        let operation = try #require(connection.start())
        #expect(!section.canTest)
        #expect(!section.isConnected)
        await operation.value
        #expect(section.canTest)
        #expect(section.isConnected)
        let switching = ServerConnectionSection(connection: connection, placeholder: "", footer: "",
                                                isSwitching: true, failure: .constant(nil))
        #expect(!switching.canTest)
        #expect(!switching.isConnected)
        connection.address = "http://127.0.0.1:3100/another-prefix"
        #expect(section.canTest)
        #expect(!section.isConnected)
        connection.address = "not-a-server"
        #expect(!section.canTest)
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
            try model.changeAddress(of: #require(model.catalog), to: "https://second.example")
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
        let revision = draft.revision
        let providers = DraftPasteboard.itemProviders(for: draft)
        #expect(providers.count == 2)
        let text = try await copiedData(from: providers[0], type: .utf8PlainText)
        #expect(String(data: text, encoding: .utf8) == draft.text)
        #expect(providers[1].suggestedName == "Original image.png")
        let image = try await copiedData(from: providers[1], type: .png)
        #expect(image == bytes)
        #expect(draft.revision == revision)
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

    @Test func siriReadsTheChannelOnScreenAndOnlyNamesOthersOnEveryServer() async throws {
        let channel = Channel(id: "first", name: "Launch", model: .init(provider: "test", name: "test"),
                              updatedAt: "2026-11-05T12:00:00Z")
        let store = try siriStore(channel, messages: [
            ChannelMessage(id: "m1", sequence: 1, timestamp: "2026-11-05T12:00:00Z", sender: .user,
                           content: .text("Can you check the build?")),
        ], request: nil)
        let catalogs = try await siriCatalogs()
        let query = ChannelQuery(intents: ChannelIntents(onScreen: { .channel(store) }, catalogs: { catalogs }))

        let expected = store.readableText(name: "Launch")
        #expect(expected.hasSuffix("You: Can you check the build?"))
        let shown = try #require(store.target)
        // The same channel ID on the second server is another channel.
        let targets = try [shown, #require(catalogs[0].target("second")), #require(catalogs[1].target("first"))]
        let missing = try #require(catalogs[1].target("missing"))
        let entities = try await query.entities(for: (targets + [missing]).map(\.identifier) + ["first"])
        #expect(entities.map(\.target) == targets)
        #expect(entities.map(\.name) == ["Launch", "second", "first"])
        #expect(entities.map(\.content) == [expected, "", ""])
        let exported = try await #require(entities.first).exported(as: .utf8PlainText)
        #expect(String(decoding: exported, as: UTF8.self) == expected)

        let offScreen = ChannelQuery(intents: ChannelIntents(onScreen: { nil }, catalogs: { catalogs }))
        #expect(try await offScreen.entities(for: [shown.identifier]).map(\.content) == [""])
    }

    @Test func siriReadsTheOpenMarkdownArtifactAndOnlyNamesOtherKinds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shell-siri-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("# Plan\n\nShip **it** today.".utf8).write(to: directory.appendingPathComponent("plan.md"))
        try Data("<html><script>track()</script><p>Page</p></html>".utf8)
            .write(to: directory.appendingPathComponent("page.html"))
        let session = ChannelArtifactSession(decodeImage: { _, _, _ in throw ChannelAttachmentError.invalidImage },
                                             download: { artifact, _ in directory.appendingPathComponent(artifact.file.path) })
        defer { session.close() }
        let plan = ChannelArtifact(file: .init(kind: "machine", path: "plan.md"), title: "Plan",
                                   url: "/api/serve/launch/plan.md")
        let page = ChannelArtifact(file: .init(kind: "machine", path: "page.html"), title: "Page",
                                   url: "/api/serve/launch/page.html")
        let store = ChannelStore(id: "first", api: try ChannelAPI(serverURL: "https://fixture.example"))
        session.configure(api: store.api, channelID: "first", artifacts: [plan, page])
        let catalogs = try await siriCatalogs()
        let intents = ChannelIntents(onScreen: { .artifact(session, in: store) }, catalogs: { catalogs })
        let artifacts = ArtifactQuery(intents: intents)
        let planID = ArtifactEntity.id(channelID: "first", artifactID: plan.id)
        let pageID = ArtifactEntity.id(channelID: "first", artifactID: page.id)
        #expect(try await artifacts.entities(for: [planID]).isEmpty)

        session.open(plan)
        await session.loadTask?.value
        let shown = try await artifacts.entities(for: [planID, pageID])
        #expect(shown.map(\.id) == [planID])
        #expect(shown.map(\.title) == ["Plan"])
        #expect(shown.map(\.kind) == ["Markdown"])
        #expect(!session.readableText.isEmpty)
        #expect(shown.map(\.content) == [session.readableText])
        // The conversation is behind the artifact, so the channel gives Siri only its name.
        let behind = try #require(store.target).identifier
        #expect(try await ChannelQuery(intents: intents).entities(for: [behind]).map(\.content) == [""])

        #expect(session.select(page.id))
        await session.loadTask?.value
        let html = try await artifacts.entities(for: [planID, pageID])
        #expect(html.map(\.id) == [pageID])
        #expect(html.map(\.kind) == ["HTML"])
        #expect(html.map(\.content) == [session.readableText])

        session.close()
        #expect(try await artifacts.entities(for: [pageID]).isEmpty)
    }

    @Test func siriSeesTheChannelScreenOnlyWhileItsInFrontAndUncovered() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            defer { model.setScenePhase(.background) }
            await model.refreshCatalog()
            model.selectedChannelID = "first"
            let store = try #require(model.selectedStore)
            model.visibleChannelID = "first"
            let first = try #require(model.target("first"))
            model.screenEntity = .channel(first)
            @MainActor func shownChannel() -> ChannelStore? { if case .channel(let shown) = model.onScreen { shown } else { nil } }
            #expect(model.onScreen == nil)

            // Siri's overlay leaves the scene inactive, and the screen behind it is still what Siri reads.
            model.setScenePhase(.inactive)
            #expect(shownChannel() === store)
            model.cover = .settings
            #expect(model.onScreen == nil)
            model.cover = nil
            model.visibleChannelID = "second"
            #expect(model.onScreen == nil)
            model.visibleChannelID = "first"
            model.screenEntity = .channel(try #require(model.target("second")))
            #expect(model.onScreen == nil)

            let artifact = ChannelArtifact(file: .init(kind: "machine", path: "plan.md"), title: "Plan")
            model.screenEntity = .artifact(first, artifactID: artifact.id)
            #expect(model.onScreen == nil)
            let session = model.artifactSession(for: store)
            defer { session.close() }
            session.open(artifact)
            guard case .artifact(let shown, let owner) = model.onScreen else {
                Issue.record("The open artifact isn't on screen.")
                return
            }
            #expect(shown === session)
            #expect(owner === store)

            let second = try model.addServer("https://second.example")
            await second.refresh()
            let elsewhere = try #require(second.target("first"))
            model.selection = elsewhere
            model.visibleChannel = elsewhere
            model.screenEntity = .channel(elsewhere)
            #expect(shownChannel()?.target == elsewhere)

            model.setScenePhase(.background)
            #expect(model.onScreen == nil)
        }
    }

    @Test func theChannelScreenNamesItsConversationToSiri() async {
        await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            defer { model.setScenePhase(.background) }
            await model.refreshCatalog()
            model.selectedChannelID = "first"
            let root = RootView(handoff: ChannelHandoffNavigation()).environment(model).environment(\.scenePhase, .inactive)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
            let host = UIHostingController(rootView: root)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            repeat {
                host.view.layoutIfNeeded()
                await Task.yield()
            } while model.screenEntity == nil && ContinuousClock.now < deadline
            #expect(model.screenEntity == model.target("first").map { .channel($0) })

            model.selectedChannelID = nil
            repeat {
                host.view.layoutIfNeeded()
                await Task.yield()
            } while model.screenEntity != nil && ContinuousClock.now < deadline.advanced(by: .seconds(2))
            #expect(model.screenEntity == nil)
        }
    }

    /// Two servers that each list channels "first" and "second".
    private func siriCatalogs() async throws -> [ChannelCatalogStore] {
        var catalogs: [ChannelCatalogStore] = []
        for server in ["https://fixture.example", "https://second.example"] {
            let catalog = ChannelCatalogStore(api: try ChannelAPI(serverURL: server, session: fixtureSession()))
            await catalog.refresh()
            catalogs.append(catalog)
        }
        return catalogs
    }

    private func siriStore(_ channel: Channel, messages: [ChannelMessage], request: ChannelMessage?) throws -> ChannelStore {
        let store = ChannelStore(id: channel.id, api: try ChannelAPI(serverURL: "https://fixture.example"))
        _ = try store.apply(.init(type: "snapshot", state: ChannelState(
            revision: 1, channel: channel,
            lead: .lead(id: "lead", profile: .init(name: "Lead", role: "Coordinator",
                                                  avatar: .init(mark: "M4 12H20", color: "#123456"))),
            members: [ChannelAgent(id: "core", name: "Core")],
            messages: messages, request: request)))
        return store
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
            let isCatalogStream = url.path.hasSuffix("/api/v1/channels")
                && request.value(forHTTPHeaderField: "Accept") == "text/event-stream"
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": isCatalogStream ? "text/event-stream" : "application/json"]))
            let catalog = ChannelCatalog(
                lead: .init(name: "Lead", role: "Coordinator", avatar: .init(mark: "M4 12H20", color: "#123456")),
                channels: ["first", "second"].map {
                    Channel(id: $0, name: $0, model: .init(provider: "test", name: "test"),
                            updatedAt: "2026-10-25T12:00:00Z")
                },
                working: ["first"]
            )
            let body = try JSONEncoder().encode(catalog)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if isCatalogStream {
                // The catalog's stream opens with the catalog and stays open until the app closes it.
                client?.urlProtocol(self, didLoad: Data(#"data: {"type":"snapshot","catalog":"#.utf8) + body
                                    + Data("}\n\n".utf8))
            } else {
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ChangeFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

@MainActor @Observable
private final class BadgeRecorder {
    var counts: [Int] = []

    func waitForCalls(_ count: Int) async {
        for await calls in Observations({ self.counts.count }) {
            if calls >= count { return }
        }
    }
}

private final class BadgeFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable { var status: Int; var data: Data }
    static let responses = Mutex<[String: Response]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try #require(request.url)
            let result = if url.path == "/api/v1/channels" {
                try #require(Self.responses.withLock { $0[url.host ?? ""] })
            } else {
                Response(status: 503, data: Data(#"{"error":"Request history unavailable."}"#.utf8))
            }
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: result.status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}

extension MobileNotificationRegistration {
    /// Whether the first server's registration is ready.
    var isReady: Bool { current.first.map { ready.contains($0.registrationID) } ?? false }
}

/// Tests that predate several servers name their channels on the first server.
extension AppModel {
    func target(_ channelID: String) -> ChannelTarget? { catalog?.target(channelID) }

    var selectedChannelID: String? {
        get { selection?.channelID }
        set { selection = newValue.flatMap(target) }
    }

    var visibleChannelID: String? {
        get { visibleChannel?.channelID }
        set { visibleChannel = newValue.flatMap(target) }
    }

    func interaction(for channelID: String) -> ChannelInteraction { interaction(for: target(channelID)!) }
}
