import Foundation
import Testing
@testable import ChannelKit

@Suite("Channel Handoff")
struct ChannelHandoffTests {
    @Test(arguments: ["studio-demo", UUID().uuidString, "channel/with:protocol-characters"])
    func activitiesCarryOnlyTheExactProtocolID(channelID: String) throws {
        let handoff = ChannelHandoff(channelID: channelID)
        let activity = NSUserActivity(activityType: ChannelHandoff.activityType)
        activity.userInfo = handoff.userInfo
        #expect(activity.userInfo?.count == 1)
        #expect(activity.userInfo?[ChannelHandoff.channelIDKey] as? String == channelID)
        #expect(ChannelHandoff(activity: activity) == handoff)
    }

    @Test func untrustedExtraFieldsCannotChangeTheDestination() {
        let activity = NSUserActivity(activityType: ChannelHandoff.activityType)
        activity.userInfo = [
            "channelID": "studio-demo",
            "serverURL": "https://another.example",
            "name": "A different channel",
            "draft": "Never import this"
        ]
        let handoff = ChannelHandoff(activity: activity)
        #expect(handoff?.channelID == "studio-demo")
        #expect(handoff?.userInfo == ["channelID": "studio-demo"])
    }

    @Test func unsupportedActivitiesAndMissingIDsHaveNoDestination() {
        let activity = NSUserActivity(activityType: ChannelHandoff.activityType)
        #expect(ChannelHandoff(activity: activity) == nil)
        activity.userInfo = ["channelID": ""]
        #expect(ChannelHandoff(activity: activity) == nil)
        activity.userInfo = ["channelID": 42]
        #expect(ChannelHandoff(activity: activity) == nil)
        let other = NSUserActivity(activityType: "dev.toybox.other")
        other.userInfo = ["channelID": "studio-demo"]
        #expect(ChannelHandoff(activity: other) == nil)
    }
}
