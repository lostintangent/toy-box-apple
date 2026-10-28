import ChannelIntelligence
import ChannelKit
import Foundation
import Observation
import SwiftUI
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
        register: @escaping (ChannelAPI, String, PushRegistration) async throws -> Bool = { _, _, _ in false },
        addNotice: @escaping (UNNotificationRequest) async throws -> Void = { _ in },
        _ work: @MainActor (UserDefaults, MobileNotificationRegistration, ChannelNotifications) async throws -> Void
    ) async throws {
        try await withDefaults { defaults in
            try await withRegistrationStore { store in
                let api = try ChannelAPI(serverURL: "https://fixture.example")
                let registration = MobileNotificationRegistration(
                    store: store, environment: .sandbox, requestToken: {}, register: register,
                    remove: { _, _ in }, subscribe: { _, _, _ in }, unsubscribe: { _, _, _ in })
                try registration.select(api: api)
                let notifications = ChannelNotifications(
                    defaults: defaults, registration: registration, readAuthorization: { .authorized }, addNotice: addNotice)
                notifications.configure(api: api)
                try await work(defaults, registration, notifications)
                await registration.waitUntilIdle()
            }
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    @Test func handoffUnavailableStaysVisibleWhenTheNormalPhoneRootIsReplaced() async {
        await withDefaults { defaults in
            let model = AppModel(arguments: [], environment: [:], bundleDefaultServerURL: nil,
                                 defaults: defaults)
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
                                              currentCatalog: { nil }) { _ in
                Issue.record("An invalid continuation opened a channel.")
            }
            host.rootView = root
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let labels = MobileAutomationTree(windows: [window]).elements.map(\.label)
            #expect(navigation.phase == .unavailable)
            #expect(labels.contains("Channel unavailable"), "\(labels)")
            #expect(labels.contains("This channel isn't available."), "\(labels)")
            #expect(labels.contains("Show Channels"), "\(labels)")
            #expect(model.selectedChannelID == nil)
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
            #expect(labels.contains("Couldn't connect notifications to this server.") == enabled, "\(labels)")
            #expect(labels.contains("Try Again") == enabled, "\(labels)")
        }
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
            try registration.select(api: ChannelAPI(serverURL: "https://first.example"))
            let id = try #require(registration.current?.registrationID)
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
            #expect(registration.current?.registrationID == id)
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
                try registration.select(api: ChannelAPI(serverURL: "https://fixture.example"))
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
    func aServerSwitchWaitsForTheOldWriteWithoutAcceptingItsAcknowledgement() async throws {
        try await withRegistrationStore { store in
            var events: [String] = []
            var created: [MobilePushRegistration] = []
            var responses: [CheckedContinuation<Void, Never>] = []
            var began: (() -> Void)?
            let registration = MobileNotificationRegistration(
                store: store, environment: .sandbox, requestToken: {},
                register: { api, _, _ in
                    events.append("register:\(api.baseURL.host ?? "")")
                    if responses.count < 2 { await withCheckedContinuation { continuation in
                        responses.append(continuation)
                        began?()
                    } }
                    return true
                },
                remove: { api, _ in events.append("delete:\(api.baseURL.host ?? "")") },
                subscribe: { _, _, _ in }, unsubscribe: { _, _, _ in })
            registration.onCreated = { created.append($0) }
            try registration.select(api: ChannelAPI(serverURL: "https://first.example"))
            let firstID = try #require(registration.current?.registrationID)
            registration.update(enabled: true, requests: true, completions: true)
            await withCheckedContinuation { continuation in
                began = { continuation.resume() }
                registration.receivedToken(Data([1]))
            }
            try registration.select(api: ChannelAPI(serverURL: "https://second.example"))
            let secondID = try #require(registration.current?.registrationID)
            registration.update(enabled: false, requests: true, completions: true)
            #expect(firstID != secondID)
            #expect(!registration.isReady)
            #expect(events == ["register:first.example"])
            let firstResponse = try #require(responses.first)
            await withCheckedContinuation { continuation in
                began = { continuation.resume() }
                firstResponse.resume()
            }
            #expect(events == ["register:first.example", "delete:first.example", "register:second.example"])
            #expect(!registration.isReady)
            #expect(created.isEmpty)
            try #require(responses.last).resume()
            await registration.waitUntilIdle()
            #expect(registration.isReady)
            #expect(created == [try #require(registration.current)])
            try registration.select(api: ChannelAPI(serverURL: "https://first.example"))
            #expect(!registration.isReady)
            #expect(registration.current?.registrationID != firstID)
            #expect(registration.current?.registrationID != secondID)
            await registration.waitUntilIdle()
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
            try registration.select(api: ChannelAPI(serverURL: "https://first.example"))
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
            try registration.select(api: ChannelAPI(serverURL: "https://first.example"))
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

    @Test(arguments: [false, true])
    func notificationAndActivityRoutesRevealOnlyRequestsFromTheSelectedRegistration(activityLink: Bool) async throws {
        try await withNotifications { defaults, registration, notifications in
            let id = try #require(registration.current?.registrationID)
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession(), notifications: notifications)
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
            try await open(.request, "first", 88, "old")
            #expect(model.selectedChannelID == "second")
            #expect(model.navigationNotice == (activityLink ? "This channel isn't available." : nil))
            #expect(model.serverURL == "https://fixture.example")
        }
    }

    @Test func nativeReplyDispatchKeepsTheOriginalPayloadAndRejectsAnOldRegistrationWithOnePlainNotice() async throws {
        var notices: [UNNotificationRequest] = []
        try await withNotifications(addNotice: { notices.append($0) }) { _, registration, notifications in
            let id = try #require(registration.current?.registrationID)
            let payload = ChannelPushPayload(kind: .request, channelID: "first", sequence: 42, registrationID: id)
            var replies = 0
            notifications.onReply = { received, text, handle in
                #expect(received == payload)
                #expect(text == "Keep the library by the desks")
                #expect(handle == "lead")
                replies += 1
                return .failed(id: "durable-outbox-id")
            }
            await notifications.receive(payload, action: ChannelNotificationCategory.reply,
                                        text: "Keep the library by the desks", handle: "lead", identifier: "request")
            #expect(replies == 1)
            #expect(notices.isEmpty)
            await notifications.receive(
                ChannelPushPayload(kind: .request, channelID: "first", sequence: 42, registrationID: "old"),
                action: ChannelNotificationCategory.reply, text: "Don't send this", handle: "lead", identifier: "old")
            #expect(replies == 1)
            #expect(notices.count == 1)
            #expect(notices.first?.content.body == "Your reply wasn't sent.")
            #expect(notices.first?.content.userInfo.isEmpty == true)
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
            @MainActor func waitFor(_ state: ChannelFollowAction.State, for store: ChannelStore) async {
                for await current in Observations({ following.state(for: store) }) {
                    if current == state { return }
                }
            }
            let first = try #require(model.catalog?.channel(id: "first"))
            try prepare(first)
            #expect(following.state(for: first) == .unavailable)
            model.observeFollowing()
            await withCheckedContinuation { continuation in
                began = { continuation.resume() }
                registration.receivedToken(Data([1]))
            }
            #expect(notifications.currentRegistration == registration.current)
            #expect(!notifications.isRegistrationReady)
            #expect(following.state(for: first) == .unavailable)
            #expect(!notifications.isEnabled)
            try #require(response).resume(returning: false)
            await registration.waitUntilIdle()
            await waitFor(.available, for: first)
            #expect(notifications.isRegistrationReady)

            try model.configure(serverURL: "https://second.example")
            let secondAPI = try #require(model.api)
            try registration.select(api: secondAPI)
            let second = try #require(model.catalog?.channel(id: "first"))
            try prepare(second)
            await waitFor(.available, for: second)
            #expect(following.state(for: first) == .unavailable)

            try registration.select(api: firstAPI)
            await waitFor(.unavailable, for: second)
            try registration.select(api: secondAPI)
            await waitFor(.available, for: second)
            #expect(!notifications.isEnabled)
        }
    }

    @Test func presentationKeepsTheVisibleChannelQuietAndCompletionsInNotificationCenter() async throws {
        try await withNotifications { _, registration, notifications in
            await notifications.enable()
            await notifications.update(channels: [], activeChannelID: "first", withdraw: false)
            let id = try #require(registration.current?.registrationID)
            let visible = ChannelPushPayload(kind: .request, channelID: "first", sequence: 42, registrationID: id)
            let other = ChannelPushPayload(kind: .request, channelID: "second", sequence: 45, registrationID: id)
            #expect(notifications.presentation(for: visible, category: ChannelNotificationCategory.request).isEmpty)
            #expect(notifications.presentation(for: other, category: ChannelNotificationCategory.request)
                    == [.banner, .list, .sound])
            #expect(notifications.presentation(for: other, category: ChannelNotificationCategory.completion) == [.list])
            notifications.disable()
            #expect(notifications.presentation(for: other, category: ChannelNotificationCategory.request).isEmpty)
            #expect(notifications.presentation(for: nil, category: ChannelNotificationCategory.replyFailed)
                    == [.banner, .list, .sound])
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
        let records: [ChannelNotifications.Delivered] = [
            .init(identifier: "answered", payload: .init(kind: .request, channelID: "first", sequence: 20, registrationID: "now")),
            .init(identifier: "waiting", payload: .init(kind: .request, channelID: "first", sequence: 40, registrationID: "now")),
            .init(identifier: "seen", payload: .init(kind: .completion, channelID: "first", sequence: 30, registrationID: "now")),
            .init(identifier: "unseen", payload: .init(kind: .completion, channelID: "first", sequence: 50, registrationID: "now")),
            .init(identifier: "open", payload: .init(kind: .request, channelID: "open", sequence: 1, registrationID: "now")),
            .init(identifier: "deleted", payload: .init(kind: .request, channelID: "gone", sequence: 1, registrationID: "now")),
            .init(identifier: "foreign", payload: .init(kind: .request, channelID: "first", sequence: 1, registrationID: "old")),
        ]
        #expect(ChannelNotifications.stale(records, channels: channels, registrationID: "now", activeChannelID: "open")
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
            #expect(notifications.completions)
            #expect(!notifications.hasLoadedAuthorization)
            await notifications.enable()
            #expect(prompts == 1)
            #expect(notifications.authorization == .authorized)
            #expect(notifications.isEnabled)
            #expect(defaults.bool(forKey: "notificationsEnabled"))
            notifications.requests = false
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
            await navigation.continueActivity(activity, currentCatalog: { model.catalog }) { id in
                model.openHandoffChannel(id: id, generation: generation)
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
            model.openHandoffChannel(id: "first", generation: generation)
            #expect(model.selectedChannelID == "second")
            let beforeSwitch = model.beginHandoffNavigation()
            try model.configure(serverURL: "https://another.example")
            model.openHandoffChannel(id: "first", generation: beforeSwitch)
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

    @Test func aWidgetRequestNeverSwitchesToItsForeignServer() async throws {
        try await withDefaults { defaults in
            let model = AppModel(arguments: ["--server", "https://fixture.example"], environment: [:],
                                 defaults: defaults, session: fixtureSession())
            model.selectedChannelID = "second"
            let request = NeedsYouRequestLink(serverURL: "https://other.example", channelID: "first", sequence: 42)
            await model.openExternalURL(try #require(request.url))
            #expect(model.serverURL == "https://fixture.example")
            #expect(model.selectedChannelID == "second")
            #expect(model.navigationNotice == "This channel isn't available.")
        }
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

    @Test(arguments: [SidebarConnection.connecting, .connected])
    func nonFailureCatalogStatesReserveNoFooterSpace(connection: SidebarConnection) {
        let host = UIHostingController(rootView: ChannelSidebarFailure(
            connection: connection, error: nil, canRetry: true, retry: {}, openSettings: {}
        ))
        host.loadViewIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        #expect(size.height == 0)
    }

    #if DEBUG
    @Test(arguments: [SidebarConnection.reconnecting, .unreachable], [false, true])
    func catalogFailuresKeepTheirHeadingErrorRetryAndUnfoldedSettings(
        connection: SidebarConnection, showsSettings: Bool
    ) throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let host = UIHostingController(rootView: ChannelSidebarFailure(
            connection: connection, error: "The server is unavailable.", canRetry: true,
            retry: {}, openSettings: {}, showsSettingsButton: showsSettings
        ))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let labels = MobileAutomationTree(windows: [window]).elements.map(\.label)
        #expect(labels.contains(try #require(connection.heading)), "\(labels)")
        #expect(labels.contains("The server is unavailable."), "\(labels)")
        #expect(labels.contains("Retry"), "\(labels)")
        #expect(labels.contains("Settings") == showsSettings, "\(labels)")
        #expect(!labels.contains("Server connection") && !labels.contains("Server Settings"), "\(labels)")
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
