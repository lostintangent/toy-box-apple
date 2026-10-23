import Foundation
import Testing
@testable import ChannelKit

struct AvatarTests {
    @Test func servedInkRoundTripsWithoutChangingLegacyAvatars() throws {
        let data = Data(##"{"mark":"M4 12H20","color":"#1e3a8a","ink":"#facc15"}"##.utf8)
        let avatar = try JSONDecoder().decode(AgentAvatar.self, from: data)
        #expect(avatar.ink == "#facc15")
        #expect(resolvedAvatarInk(for: avatar) == "#facc15")
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(avatar))
                == JSONDecoder().decode(JSONValue.self, from: data))
        let legacy = try JSONDecoder().decode(
            AgentAvatar.self, from: Data(##"{"mark":"M4 12H20","color":"#0891b2"}"##.utf8)
        )
        #expect(legacy.ink == nil)
        #expect(resolvedAvatarInk(for: legacy) == "#000000")
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(legacy))
                == .object(["mark": .string("M4 12H20"), "color": .string("#0891b2")]))
    }

    @Test func requestedInkMustReachTheUnroundedThreeToOneThreshold() {
        #expect(ink(on: "#000000", requested: "#595959") == "#ffffff")
        #expect(ink(on: "#000000", requested: "#5a5a5a") == "#5a5a5a")
        #expect(ink(on: "#ffffff", requested: "#00ff00") == "#000000")
        #expect(ink(on: "#ffffff", requested: "#ff0000") == "#ff0000")
        #expect(ink(on: "#1E3A8A", requested: "#FACC15") == "#FACC15")
    }

    @Test func automaticInkUsesLinearLuminanceAndTheStrongerContrast() {
        #expect(ink(on: "#000000") == "#ffffff")
        #expect(ink(on: "#ffffff") == "#000000")
        #expect(ink(on: "#757575") == "#ffffff")
        #expect(ink(on: "#767676") == "#000000")
        #expect(ink(on: "#ff0000") == "#000000")
        #expect(ink(on: "#00ff00") == "#000000")
        #expect(ink(on: "#0000ff") == "#ffffff")
        #expect(ink(on: "#123") == ink(on: "#112233"))
        #expect(ink(on: "ABCDEF") == ink(on: "#abcdef"))
    }

    @Test(arguments: ["#fff", "facc15", "#ffcc15ff", "#gggggg", "white", ""])
    func malformedRequestedInkUsesAutomaticContrast(requested: String) {
        #expect(ink(on: "#1e3a8a", requested: requested) == "#ffffff")
    }

    @Test(arguments: ["", "#12", "#12345g", "#12345678", "+12345", "navy"])
    func invalidBackgroundHasNoResolvedInk(background: String) {
        #expect(ink(on: background, requested: "#facc15") == nil)
    }

    @Test func servedLeadProfileControlsUnopenedChannelIdentity() throws {
        let data = Data(#"""
        {"version":1,"channels":[],"members":[],"working":["channel"],
         "lead":{"name":"Guide","role":"A served role.",
                 "avatar":{"mark":"M4 12H20","color":"#1e3a8a","ink":"#facc15"}}}
        """#.utf8)
        let catalog = try JSONDecoder().decode(ChannelCatalog.self, from: data)
        let profile = catalog.lead
        let agent = ChannelAgent.lead(id: "channel", profile: profile)
        #expect(agent.id == "channel")
        #expect(agent.name == "Guide")
        #expect(agent.role == "A served role.")
        #expect(agent.avatar == profile.avatar)
        #expect(agent.avatar?.ink == "#facc15")
        #expect(catalog.members.isEmpty)
        #expect(try JSONDecoder().decode(ChannelCatalog.self, from: JSONEncoder().encode(catalog)) == catalog)
    }

    @Test(arguments: [#"{"version":1,"channels":[],"members":[]}"#,
                      #"{"version":1,"channels":[],"members":[],"lead":null}"#])
    func absentCatalogLeadIsAProtocolError(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChannelCatalog.self, from: Data(json.utf8))
        }
    }

    @Test func malformedPresentLeadIsNotSilentlyDropped() {
        let data = Data(#"{"version":1,"channels":[],"members":[],"lead":{"name":"Lead"}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ChannelCatalog.self, from: data) }
    }

    private func ink(on background: String, requested: String? = nil) -> String? {
        resolvedAvatarInk(for: .init(mark: "M4 12H20", color: background, ink: requested))
    }
}
