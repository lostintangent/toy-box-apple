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

    @Test func activityStateUsesUnixSecondsWithAnUnconfiguredActivityKitDecoder() throws {
        struct Envelope: Decodable {
            struct APS: Decodable {
                var timestamp: Double
                var staleDate: Double
                var state: ChannelActivityAttributes.ContentState
                enum CodingKeys: String, CodingKey {
                    case timestamp
                    case staleDate = "stale-date"
                    case state = "content-state"
                }
            }
            var aps: APS
        }
        let file = try #require(Bundle.module.url(forResource: "push-activity", withExtension: "apns",
                                                  subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
        let state = fixture.aps.state
        #expect(state.updatedAt.ISO8601Format() == "2026-10-27T07:30:00Z")
        #expect(state.updatedAt.timeIntervalSince1970 == fixture.aps.timestamp)
        #expect(state.staleDate?.timeIntervalSince1970 == fixture.aps.staleDate)
        #expect(state.tasksDone == 1)
        #expect(state.tasksTotal == 3)
        #expect(state.workingAgents.map(\.name) == ["Lead"])
        #expect(state.waitingRequestSequence == 15)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(ChannelActivityAttributes.ContentState.self, from: data) == state)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["updatedAt"] as? Double == 1793086200)
        for ending in [ChannelActivityAttributes.Ending.completed, .stopped, .expired,
                       .channelDeleted, .serverChanged, .tasksRemoved] {
            var ended = state
            ended.ending = ending
            #expect(ended.staleDate == nil)
            #expect(try JSONDecoder().decode(ChannelActivityAttributes.ContentState.self,
                                             from: JSONEncoder().encode(ended)) == ended)
        }
    }
}
