import ChannelClient
import ChannelKit
import Foundation
import Testing
import UserNotifications
@testable import ToyBoxMobileIntegrations

@MainActor
private final class FakeReplyCenter {
    var categories: Set<UNNotificationCategory> = []
    var writes = 0
    private let acceptsWrites: Bool

    init(acceptsWrites: Bool = true) {
        self.acceptsWrites = acceptsWrites
    }

    func publisher() -> ReplyCategoryPublisher {
        ReplyCategoryPublisher(base: ReplyCategories.baseCategories(),
            read: { (categories: self.categories, delivered: Set<String>()) },
            write: { categories in
                self.writes += 1
                if self.acceptsWrites { self.categories = categories }
            })
    }
}

struct MobileNotificationHandlerTests {
    @Test(arguments: [ChannelPushPayload.Kind.request, .completion])
    @MainActor func displayReadyAlertsGainOnlyTheirServerAndReloadWidgetsBeforeDelivery(kind: ChannelPushPayload.Kind) async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory)
            .select(serverURL: "https://unreachable.example.test")
        let original = Self.content(kind: kind, registration: registration)
        var events: [String] = []
        let handler = MobileNotificationHandler(directory: directory, reloadWidgets: { events.append("reload") })
        let delivered = await handler.process(original)
        events.append("delivered")
        #expect(events == ["reload", "delivered"])
        let expected = try #require(original.mutableCopy() as? UNMutableNotificationContent)
        expected.userInfo["serverURL"] = registration.serverURL
        #expect(delivered.isEqual(expected))
        #expect(delivered.title == "Studio")
        #expect(delivered.body == original.body)
        #expect(delivered.threadIdentifier == "\(registration.registrationID):studio")
        #expect(delivered.userInfo["handle"] as? String == "lead")
        #expect(delivered.badge == 2)
    }

    @Test(arguments: ["missing", "different", "malformed"])
    @MainActor func invalidRegistrationsDisableActionsAndBadgeChangesWithoutReloadingWidgets(failure: String) async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = MobilePushRegistration(serverURL: "https://server.test", registrationID: UUID().uuidString)
        if failure != "missing" {
            _ = try MobilePushRegistrationStore(directory: directory).select(serverURL: "https://other.test")
        }
        let original = Self.content(registration: registration)
        if failure == "malformed" { original.userInfo["kind"] = "unknown" }
        let handler = MobileNotificationHandler(directory: directory,
            reloadWidgets: { Issue.record("Invalid routing must not reload widgets.") })
        let delivered = await handler.process(original)
        let expected = try #require(original.mutableCopy() as? UNMutableNotificationContent)
        expected.categoryIdentifier = ""
        expected.badge = nil
        #expect(delivered.isEqual(expected))
        #expect(original.categoryIdentifier == "request")
        #expect(original.badge == 2)
    }

    @Test @MainActor func requestsWithSuggestedRepliesPublishTheirCategoryBeforeReturningIt() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory)
            .select(serverURL: "https://unreachable.example.test")
        let original = Self.content(registration: registration, replies: ["Yes", "No"])
        let center = FakeReplyCenter()
        let handler = MobileNotificationHandler(directory: directory, reloadWidgets: {},
                                                replyCategories: center.publisher())
        let delivered = await handler.process(original)
        let identifier = ReplyCategories.identifier(labels: ["Yes", "No"])
        #expect(delivered.categoryIdentifier == identifier)
        #expect(delivered.badge == 2)
        #expect(delivered.userInfo["replies"] as? [String] == ["Yes", "No"])
        #expect(original.categoryIdentifier == "request")
        #expect(center.categories.map(\.identifier).contains(identifier))
    }

    @Test @MainActor func requestsWithoutTwoToFourUsableRepliesKeepOnlyTheReplyField() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory)
            .select(serverURL: "https://unreachable.example.test")
        let center = FakeReplyCenter()
        let handler = MobileNotificationHandler(directory: directory, reloadWidgets: {},
                                                replyCategories: center.publisher())
        let invalid: [[String]?] = [nil, ["Only one"], ["A", "B", "C", "D", "E"], ["Yes", " "]]
        for replies in invalid {
            let original = Self.content(registration: registration, replies: replies)
            let delivered = await handler.process(original)
            #expect(delivered.categoryIdentifier == "request")
            #expect(delivered.userInfo["serverURL"] as? String == registration.serverURL)
        }
        #expect(center.writes == 0)
    }

    @Test @MainActor func repliesThatDoNotRegisterFallBackToTheReplyField() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory)
            .select(serverURL: "https://unreachable.example.test")
        let original = Self.content(registration: registration, replies: ["Yes", "No"])
        let center = FakeReplyCenter(acceptsWrites: false)
        let handler = MobileNotificationHandler(directory: directory, reloadWidgets: {},
                                                replyCategories: center.publisher())
        let delivered = await handler.process(original)
        #expect(delivered.categoryIdentifier == "request")
        #expect(delivered.userInfo["serverURL"] as? String == registration.serverURL)
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tbm-notification-\(UUID())")
    }

    private static func content(kind: ChannelPushPayload.Kind = .request,
                                registration: MobilePushRegistration,
                                replies: [String]? = nil) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Studio"
        content.body = kind == .request ? "Which door should we ship?" : "Completed \u{201C}Ship the door\u{201D}"
        content.sound = .default
        content.categoryIdentifier = kind.rawValue
        content.threadIdentifier = "\(registration.registrationID):studio"
        content.badge = 2
        content.userInfo = ["kind": kind.rawValue, "channelID": "studio", "sequence": 15,
                            "registrationID": registration.registrationID, "handle": "lead", "extra": "untouched"]
        if let replies { content.userInfo["replies"] = replies }
        return content
    }
}
