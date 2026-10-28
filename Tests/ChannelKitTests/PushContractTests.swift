import Foundation
import Testing
@testable import ChannelKit

struct PushContractTests {
    @Test(arguments: [ChannelPushPayload.Kind.request, .completion])
    func fixtureContainsOnlyRoutingFieldsBesideTheSystemAlert(kind: ChannelPushPayload.Kind) throws {
        let file = try #require(Bundle.module.url(forResource: "push-\(kind.rawValue)", withExtension: "apns",
                                                  subdirectory: "Fixtures"))
        let data = try Data(contentsOf: file)
        let payload = try JSONDecoder().decode(ChannelPushPayload.self, from: data)
        let info = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(try ChannelPushPayload(userInfo: info) == payload)
        #expect(payload.kind == kind)
        #expect(payload.channelID == "studio-demo")
        #expect(payload.registrationID == "00000000-0000-4000-8000-000000000001")
        #expect(Set(info.keys) == ["aps", "kind", "channelID", "sequence", "registrationID"])
        #expect(Set(payload.userInfo.keys) == ["kind", "channelID", "sequence", "registrationID"])
        #expect(try ChannelPushPayload(userInfo: payload.userInfo) == payload)
        let aps = try #require(info["aps"] as? [String: Any])
        #expect(aps["category"] as? String == kind.rawValue)
        #expect(aps["mutable-content"] as? Int == 1)
    }

    @Test func categoriesMatchTheMacAndMalformedRoutingDoesNotDecode() throws {
        #expect(ChannelNotificationCategory.request == "request")
        #expect(ChannelNotificationCategory.completion == "completion")
        #expect(ChannelNotificationCategory.reply == "reply")
        #expect(ChannelNotificationCategory.replyFailed == "replyFailed")
        let payload = ChannelPushPayload(kind: .request, channelID: "channel", sequence: 15, registrationID: "device")
        let invalid: [(String, Any)] = [
            ("kind", "unknown"), ("channelID", ""), ("sequence", 0), ("sequence", -1),
            ("sequence", true), ("registrationID", ""),
        ]
        for (key, value) in invalid {
            var info = payload.userInfo
            info[key] = value
            #expect(throws: (any Error).self) { try ChannelPushPayload(userInfo: info) }
        }
        var info = payload.userInfo
        info["aps"] = NSObject()
        #expect(try ChannelPushPayload(userInfo: info) == payload)
    }

    @Test func activityLinksCarryOnlyTheRegistrationScopedDestination() throws {
        for sequence in [nil, 15] as [Int?] {
            let link = ChannelActivityLink(channelID: "studio / &", registrationID: "device", sequence: sequence)
            let url = try #require(link.url)
            #expect(ChannelActivityLink(url: url) == link)
            #expect(!url.absoluteString.contains("server"))
        }
        let prefix = "toybox-desktop://activity?channel=studio&registration=device"
        for suffix in ["&sequence=0", "&sequence=-1", "&sequence", "&sequence=1&sequence=2",
                       "&server=https://other.test", "#fragment"] {
            let url = try #require(URL(string: prefix + suffix))
            #expect(ChannelActivityLink(url: url) == nil)
        }
        #expect(ChannelActivityLink(channelID: "", registrationID: "device").url == nil)
        #expect(ChannelActivityLink(channelID: "studio", registrationID: "").url == nil)
        #expect(ChannelActivityLink(channelID: "studio", registrationID: "device", sequence: 0).url == nil)
    }

    @Test func activityAttributesPersistTheOriginalStartSeparatelyFromContentUpdates() throws {
        let startedAt = Date(timeIntervalSince1970: 1793086200)
        let attributes = ChannelActivityAttributes(
            channelID: "studio", channelName: "Studio", registrationID: "registration", startedAt: startedAt
        )
        let data = try JSONEncoder().encode(attributes)
        let restored = try JSONDecoder().decode(ChannelActivityAttributes.self, from: data)
        #expect(restored == attributes)
        #expect(restored.startedAt == startedAt)
        let content = ChannelActivityAttributes.ContentState(
            tasksDone: 1, tasksTotal: 3, updatedAt: startedAt.addingTimeInterval(60)
        )
        let state = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any])
        #expect(state["startedAt"] == nil)
    }

    @Test func activityProjectionUsesRootProgressAndLivePresenceRatherThanOldAgentStatus() throws {
        let file = try #require(Bundle.module.url(forResource: "channel-snapshot", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        var state = try JSONDecoder().decode(ChannelState.self, from: Data(contentsOf: file))
        state.channel.tasks = [
            .init(id: "one", title: "One", status: "done",
                  children: [.init(id: "child", title: "Still pending")]),
            .init(id: "two", title: "Two", children: [.init(id: "other-child", title: "Done", status: "done")]),
        ]
        state.channel.requestSequence = 15
        state.lead.status = .init(state: "waiting")
        state.members = [.init(id: "member", name: "Member", status: .init(state: "working"))]
        state.presence = [state.lead.id: .init(state: "working"), "member": .init(state: "waiting"),
                          "removed": .init(state: "working")]
        let now = Date(timeIntervalSince1970: 1793086200)
        let projection = ChannelActivityAttributes.ContentState(state: state, updatedAt: now)
        #expect(projection.workingAgents.map(\.id) == [state.lead.id])
        #expect(projection.tasksDone == 1)
        #expect(projection.tasksTotal == 2)
        #expect(projection.waitingRequestSequence == 15)
        #expect(projection.updatedAt == now)
        #expect(projection.ending == nil)
        #expect(projection.staleDate == now.addingTimeInterval(15 * 60))

        state.presence = [:]
        let quiet = ChannelActivityAttributes.ContentState(state: state, updatedAt: now)
        #expect(quiet.workingAgents.isEmpty)
        #expect(quiet.ending == nil)
        state.channel.tasks[1].status = "done"
        let completed = ChannelActivityAttributes.ContentState(state: state, updatedAt: now)
        #expect(completed.ending == .completed)
        #expect(completed.waitingRequestSequence == 15)
        #expect(completed.staleDate == nil)
        state.channel.tasks = []
        let removed = ChannelActivityAttributes.ContentState(state: state, updatedAt: now)
        #expect(removed.tasksTotal == 0)
        #expect(removed.ending == .tasksRemoved)
        #expect(removed.staleDate == nil)
    }

    @Test(arguments: ["push-activity-working", "push-activity-quiet", "push-activity",
                       "push-activity-completed", "push-activity-ended", "push-activity-stale"])
    func activityFixturesMatchTheNativeContentCodecAndAPNsFreshness(name: String) throws {
        let file = try #require(Bundle.module.url(forResource: name, withExtension: "apns", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: file)
        #expect(data.count <= 4096)
        let push = try JSONDecoder().decode(ActivityEnvelope.self, from: data).aps
        #expect(push.timestamp == 1793086200)
        #expect(push.staleDate == push.state.staleDate?.timeIntervalSince1970)
        #expect((push.event == "end") == (push.state.ending != nil))
        #expect(push.dismissalDate == (push.state.ending == nil ? nil : push.timestamp + 900))
        let encoded = try JSONEncoder().encode(push.state)
        #expect(try JSONDecoder().decode(ChannelActivityAttributes.ContentState.self, from: encoded) == push.state)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["updatedAt"] as? Double == push.state.updatedAt.timeIntervalSince1970)
        #expect(push.state.tasksTotal == (name == "push-activity-ended" ? 0 : 3))
        switch name {
        case "push-activity-working":
            #expect(!push.state.workingAgents.isEmpty)
            #expect(push.state.waitingRequestSequence == nil)
        case "push-activity-quiet":
            #expect(push.state.workingAgents.isEmpty)
            #expect(push.state.ending == nil)
            #expect(push.state.tasksDone < push.state.tasksTotal)
        case "push-activity":
            #expect(push.state.waitingRequestSequence == 15)
            #expect(push.state.updatedAt.ISO8601Format() == "2026-10-27T07:30:00Z")
            #expect(push.state.workingAgents.map(\.name) == ["Lead"])
            #expect(push.state.tasksDone == 1)
        case "push-activity-completed":
            #expect(push.state.ending == .completed)
            #expect(push.state.tasksDone == push.state.tasksTotal)
        case "push-activity-ended":
            #expect(push.state.ending == .tasksRemoved)
            #expect(push.state.tasksDone == 0)
        case "push-activity-stale":
            #expect(try #require(push.staleDate) < push.timestamp)
            #expect(push.state.updatedAt.timeIntervalSince1970 == push.timestamp - 16 * 60)
        default: Issue.record("Unexpected fixture.")
        }
    }

    private struct ActivityEnvelope: Decodable {
        struct APS: Decodable {
            var event: String
            var timestamp: Double
            var staleDate: Double?
            var dismissalDate: Double?
            var state: ChannelActivityAttributes.ContentState
            enum CodingKeys: String, CodingKey {
                case event, timestamp
                case staleDate = "stale-date", dismissalDate = "dismissal-date", state = "content-state"
            }
        }
        var aps: APS
    }
}
