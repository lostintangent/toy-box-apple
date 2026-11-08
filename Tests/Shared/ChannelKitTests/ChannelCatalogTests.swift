import Foundation
import Testing
@testable import ChannelKit

struct ChannelCatalogTests {
    let lead = ChannelLeadProfile(name: "Lead", role: "Coordinates.", avatar: .init(mark: "M4 12H20", color: "#123456"))

    func channel(_ id: String, updatedAt: String, name: String? = nil) -> Channel {
        Channel(id: id, name: name ?? id, model: .init(provider: "p", name: "m"), updatedAt: updatedAt)
    }

    func event(_ json: String) throws -> ChannelCatalogEvent {
        try JSONDecoder().decode(ChannelCatalogEvent.self, from: Data(json.utf8))
    }

    @Test func eventsDecodeTheServersShapes() throws {
        let snapshot = try event("""
            {"type":"snapshot","catalog":{"version":1,"channels":[],"members":[],"working":["a"],
             "lead":{"name":"Lead","role":"Coordinates.","avatar":{"mark":"M4 12H20","color":"#123456"}}}}
            """)
        #expect(snapshot == .snapshot(ChannelCatalog(lead: lead, working: ["a"])))
        #expect(try event(#"{"type":"working","working":["a","b"]}"#) == .working(["a", "b"]))
        let upserted = try event("""
            {"type":"channel.upserted","channel":{"id":"c","name":"C","model":{"provider":"p","name":"m"},
             "tasks":[],"latestSequence":0,"seenThrough":0,"updatedAt":"2026-10-01T00:00:00Z","revision":7}}
            """)
        #expect(upserted == .channelUpserted(channel("c", updatedAt: "2026-10-01T00:00:00Z", name: "C")))
        #expect(try event(#"{"type":"channel.deleted","channelId":"c"}"#) == .channelDeleted(channelId: "c"))
        #expect(try event(#"{"type":"channel.member.upserted","member":{"id":"m","channelId":"c","name":"M"}}"#)
                == .memberUpserted(ChannelAgent(id: "m", name: "M", channelId: "c")))
        #expect(try event(#"{"type":"channel.member.deleted","channelId":"c","agentId":"m"}"#)
                == .memberDeleted(channelId: "c", agentId: "m"))
        #expect(try event(#"{"type":"channel.archived","channelId":"c"}"#) == .unknown("channel.archived"))
        #expect(throws: (any Error).self) { try event(#"{"type":"channel.deleted"}"#) }
    }

    /// The channel list stops sending each channel's tasks, which only its snapshot needs.
    @Test func channelsWithoutTasksStillDecode() throws {
        let entry = #"{"id":"c","name":"C","model":{"provider":"p","name":"m"},"latestSequence":4,"seenThrough":2,"requestSequence":4,"updatedAt":"2026-10-01T00:00:00Z"}"#
        let catalog = try JSONDecoder().decode(ChannelCatalog.self, from: Data("""
            {"version":1,"channels":[\(entry)],"members":[],
             "lead":{"name":"Lead","role":"Coordinates.","avatar":{"mark":"M4 12H20","color":"#123456"}}}
            """.utf8))
        var expected = channel("c", updatedAt: "2026-10-01T00:00:00Z", name: "C")
        expected.latestSequence = 4
        expected.seenThrough = 2
        expected.requestSequence = 4
        #expect(catalog.channels == [expected])
        #expect(try event(#"{"type":"channel.upserted","channel":\#(entry)}"#) == .channelUpserted(expected))
    }

    @Test func upsertsKeepTheJSONRoutesOrder() {
        var catalog = ChannelCatalog(lead: lead, channels: [
            channel("b", updatedAt: "2026-10-03T00:00:00Z"),
            channel("a", updatedAt: "2026-10-02T00:00:00Z"),
            channel("c", updatedAt: "2026-10-02T00:00:00Z"),
        ])
        catalog.apply(.channelUpserted(channel("c", updatedAt: "2026-10-04T00:00:00Z", name: "Renamed")))
        #expect(catalog.channels.map(\.id) == ["c", "b", "a"])
        #expect(catalog.channels.first?.name == "Renamed")
        catalog.apply(.channelUpserted(channel("d", updatedAt: "2026-10-03T00:00:00Z")))
        #expect(catalog.channels.map(\.id) == ["c", "b", "d", "a"])
        catalog.apply(.channelUpserted(channel("e", updatedAt: "2026-09-01T00:00:00Z")))
        #expect(catalog.channels.map(\.id) == ["c", "b", "d", "a", "e"])
    }

    @Test func membersArriveFirstAndLeaveWithTheirChannel() {
        var catalog = ChannelCatalog(lead: lead, channels: [channel("c", updatedAt: "2026-10-01T00:00:00Z"),
                                                            channel("d", updatedAt: "2026-10-01T00:00:00Z")],
                                     members: [ChannelAgent(id: "m1", name: "One", channelId: "c"),
                                               ChannelAgent(id: "m2", name: "Two", channelId: "d")])
        catalog.apply(.memberUpserted(ChannelAgent(id: "m3", name: "Three", channelId: "c")))
        #expect(catalog.members.map(\.id) == ["m3", "m1", "m2"])
        catalog.apply(.memberUpserted(ChannelAgent(id: "m1", name: "Renamed", channelId: "c")))
        #expect(catalog.members.map(\.name) == ["Three", "Renamed", "Two"])
        catalog.apply(.memberDeleted(channelId: "c", agentId: "m3"))
        #expect(catalog.members.map(\.id) == ["m1", "m2"])
        catalog.apply(.channelDeleted(channelId: "c"))
        #expect(catalog.channels.map(\.id) == ["d"])
        #expect(catalog.members.map(\.id) == ["m2"])
    }

    @Test func snapshotsReplaceAndWorkingAndUnknownChangeOnlyTheirPart() {
        var catalog = ChannelCatalog(lead: lead, channels: [channel("c", updatedAt: "2026-10-01T00:00:00Z")])
        let before = catalog
        catalog.apply(.unknown("channel.archived"))
        #expect(catalog == before)
        catalog.apply(.working(["c"]))
        #expect(catalog.working == ["c"])
        #expect(catalog.channels == before.channels)
        let replacement = ChannelCatalog(lead: lead, channels: [channel("d", updatedAt: "2026-10-02T00:00:00Z")])
        catalog.apply(.snapshot(replacement))
        #expect(catalog == replacement)
    }
}
