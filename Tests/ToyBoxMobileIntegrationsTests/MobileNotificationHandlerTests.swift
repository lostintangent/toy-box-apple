import ChannelKit
import Foundation
import Testing
import UserNotifications
@testable import ToyBoxMobileIntegrations

struct MobileNotificationHandlerTests {
    @Test(arguments: [ChannelPushPayload.Kind.request, .completion])
    @MainActor func displayReadyAlertsReturnUnchangedAndReloadWidgetsBeforeDelivery(kind: ChannelPushPayload.Kind) throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = try MobilePushRegistrationStore(directory: directory)
            .select(serverURL: "https://unreachable.example.test")
        let original = Self.content(kind: kind, registration: registration)
        var events: [String] = []
        let handler = MobileNotificationHandler(directory: directory, reloadWidgets: { events.append("reload") })
        let delivered = handler.process(original)
        events.append("delivered")
        #expect(events == ["reload", "delivered"])
        #expect(delivered === original)
        #expect(delivered.title == "Studio")
        #expect(delivered.body == original.body)
        #expect(delivered.threadIdentifier == "\(registration.registrationID):studio")
        #expect(delivered.userInfo["handle"] as? String == "lead")
        #expect(delivered.badge == 2)
    }

    @Test(arguments: ["missing", "different", "malformed"])
    @MainActor func invalidRegistrationsDisableActionsAndBadgeChangesWithoutReloadingWidgets(failure: String) throws {
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
        let delivered = handler.process(original)
        let expected = try #require(original.mutableCopy() as? UNMutableNotificationContent)
        expected.categoryIdentifier = ""
        expected.badge = nil
        #expect(delivered.isEqual(expected))
        #expect(original.categoryIdentifier == "request")
        #expect(original.badge == 2)
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tbm-notification-\(UUID())")
    }

    private static func content(kind: ChannelPushPayload.Kind = .request,
                                registration: MobilePushRegistration) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Studio"
        content.body = kind == .request ? "Which door should we ship?" : "Completed \u{201C}Ship the door\u{201D}"
        content.sound = .default
        content.categoryIdentifier = kind.rawValue
        content.threadIdentifier = "\(registration.registrationID):studio"
        content.badge = 2
        content.userInfo = ["kind": kind.rawValue, "channelID": "studio", "sequence": 15,
                            "registrationID": registration.registrationID, "handle": "lead", "extra": "untouched"]
        return content
    }
}
