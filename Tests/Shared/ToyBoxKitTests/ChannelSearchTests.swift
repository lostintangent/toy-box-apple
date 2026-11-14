import ToyBoxKit
import Testing

struct ChannelSearchTests {
    @Test func matchingUsesTheNamePurposeAndFolderButNotTransportMetadata() {
        var channel = Channel(id: "internal-id", name: "Café", model: .init(provider: "hidden-provider", name: "model"),
                              updatedAt: "2026-10-25T00:00:00Z")
        channel.purpose = "Building a companion"
        channel.directory = "/workspace/Studio"
        for query in ["", "cafe", "COMPANION", "studio"] {
            #expect(channel.matches(query), "\(query)")
        }
        for query in ["internal-id", "hidden-provider", "unmatched"] {
            #expect(!channel.matches(query), "\(query)")
        }
        channel.purpose = nil
        channel.directory = nil
        #expect(!channel.matches("companion"))
        #expect(channel.matches("cafe"))
    }

    @Test func choicesPutUpToThreeMatchingRecentsFirstThenTheRestAToZ() {
        func channel(_ id: String, _ name: String, purpose: String? = nil) -> Channel {
            var channel = Channel(id: id, name: name, model: .init(provider: "p", name: "m"),
                                  updatedAt: "2026-10-25T00:00:00Z")
            channel.purpose = purpose
            return channel
        }
        let channels = [channel("z", "Zebra"), channel("b2", "Beta"), channel("b1", "Beta"),
                        channel("a", "Alpha", purpose: "Pixel editor"), channel("p", "Pixels"),
                        channel("g", "GistPad"), channel("d", "Documint")]
        let all = channels.choices(matching: "", recentIDs: ["p", "gone", "z", "a", "g"])
        #expect(all.recent.map(\.id) == ["p", "z"])
        #expect(all.others.map(\.id) == ["a", "b1", "b2", "d", "g"])
        let pixel = channels.choices(matching: "pixel", recentIDs: ["z", "a"])
        #expect(pixel.recent.map(\.id) == ["a"])
        #expect(pixel.others.map(\.id) == ["p"])
        #expect(channels.choices(matching: "", recentIDs: []).recent.isEmpty)
    }
}
