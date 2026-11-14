import ToyBoxKit
import Foundation
import Testing
import UserNotifications
@testable import ToyBoxClient

@MainActor
private final class FakeNotificationCenter {
    var categories: Set<UNNotificationCategory> = []
    var delivered: Set<String> = []
    var writes = 0

    func publisher(base: Set<UNNotificationCategory> = ReplyCategories.baseCategories()) -> ReplyCategoryPublisher {
        ReplyCategoryPublisher(base: base,
            read: { (categories: self.categories, delivered: self.delivered) },
            write: { categories in
                self.writes += 1
                self.categories = categories
            })
    }
}

struct ReplyCategoriesTests {
    @Test func identifiersDependOnEveryLabelInOrder() {
        let identifier = ReplyCategories.identifier(labels: ["Yes", "No"])
        #expect(identifier == ReplyCategories.identifier(labels: ["Yes", "No"]))
        #expect(identifier.hasPrefix(ReplyCategories.identifierPrefix))
        #expect(identifier != ReplyCategories.identifier(labels: ["No", "Yes"]))
        #expect(identifier != ReplyCategories.identifier(labels: ["Yes", "Maybe"]))
        // Length prefixes keep label boundaries unambiguous.
        #expect(ReplyCategories.identifier(labels: ["Ye", "sNo"]) != identifier)
    }

    @Test func identifierMatchesItsPinnedDigest() {
        // Pinned so every process, including a relaunched extension, derives the same identifier.
        #expect(ReplyCategories.identifier(labels: ["Yes", "No"])
            == "request-replies.b20e1b5a1247f55a004397324bf3865fcce147b773b80835a3c05bfcbdde6fe8")
    }

    @Test func categoryHasTheReplyFieldThenOneActionPerLabel() {
        let category = ReplyCategories.category(labels: ["Yes", "No", "Later"])
        #expect(category.identifier == ReplyCategories.identifier(labels: ["Yes", "No", "Later"]))
        #expect(category.actions.first is UNTextInputNotificationAction)
        #expect(category.actions.map(\.identifier) == [
            ChannelNotificationCategory.reply, "reply-choice.0", "reply-choice.1", "reply-choice.2",
        ])
        #expect(category.actions.map(\.title) == ["Reply", "Yes", "No", "Later"])
    }

    @Test func mergeKeepsOnlyReplyCategoriesThatDeliveredNotificationsUse() {
        let delivered = ReplyCategories.category(labels: ["Yes", "No"])
        let undelivered = ReplyCategories.category(labels: ["Maybe", "Never"])
        let other = UNNotificationCategory(identifier: "other.category", actions: [], intentIdentifiers: [])
        let current: Set<UNNotificationCategory> = ReplyCategories.baseCategories().union([delivered, undelivered, other])
        let merged = ReplyCategories.merged(current: current, delivered: [delivered.identifier],
                                            base: ReplyCategories.baseCategories(), adding: nil)
        let expected = Set(ReplyCategories.baseCategories().map(\.identifier))
            .union([delivered.identifier, other.identifier])
        #expect(Set(merged.map(\.identifier)) == expected)
    }

    @Test func mergeIncludesTheAddedCategoryBeforeAnyNotificationDeliversIt() {
        let added = ReplyCategories.category(labels: ["Yes", "No"])
        let merged = ReplyCategories.merged(current: [], delivered: [], base: ReplyCategories.baseCategories(),
                                            adding: added)
        #expect(merged.contains { $0.identifier == added.identifier })
    }

    @MainActor @Test func publishWritesOnlyWhenTheRegistrationChanges() async {
        let center = FakeNotificationCenter()
        let publisher = center.publisher()
        let category = ReplyCategories.category(labels: ["Yes", "No"])
        await publisher.publish(adding: category)
        #expect(center.writes == 1)
        let registered = await publisher.isRegistered(identifier: category.identifier)
        #expect(registered)
        await publisher.publish(adding: category)
        #expect(center.writes == 1)
    }

    @MainActor @Test func launchPublishKeepsReplyCategoriesThatDeliveredNotificationsStillUse() async {
        let center = FakeNotificationCenter()
        let kept = ReplyCategories.category(labels: ["Yes", "No"])
        let dropped = ReplyCategories.category(labels: ["Maybe", "Never"])
        center.categories = ReplyCategories.baseCategories().union([kept, dropped])
        center.delivered = [kept.identifier]
        await center.publisher().publish()
        let identifiers = Set(center.categories.map(\.identifier))
        #expect(identifiers.contains(kept.identifier))
        #expect(!identifiers.contains(dropped.identifier))
    }

    @MainActor @Test func aWriteThatDoesNotRegisterIsReportedToTheCaller() async {
        let publisher = ReplyCategoryPublisher(base: ReplyCategories.baseCategories(),
            read: { (categories: Set<UNNotificationCategory>(), delivered: Set<String>()) },
            write: { _ in })
        let category = ReplyCategories.category(labels: ["Yes", "No"])
        await publisher.publish(adding: category)
        let registered = await publisher.isRegistered(identifier: category.identifier)
        #expect(!registered)
    }

    @MainActor @Test func overlappingPublishesKeepEachOthersCategories() async {
        let center = FakeNotificationCenter()
        let publisher = center.publisher()
        let firstLabels = ["Yes", "No"]
        let secondLabels = ["Maybe", "Never"]
        async let a: Void = publisher.publish(adding: ReplyCategories.category(labels: firstLabels))
        async let b: Void = publisher.publish(adding: ReplyCategories.category(labels: secondLabels))
        _ = await (a, b)
        let identifiers = Set(center.categories.map(\.identifier))
        #expect(identifiers.isSuperset(of: [ReplyCategories.identifier(labels: firstLabels),
                                            ReplyCategories.identifier(labels: secondLabels)]))
    }
}
