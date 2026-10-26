import ChannelKit
import Testing

struct ChannelSearchTests {
    @Test func matchingUsesTheNamePurposeAndFolderButNotTransportMetadata() {
        var channel = Channel(id: "internal-id", name: "Café", model: .init(provider: "hidden-provider", name: "model"),
                              updatedAt: "2026-10-25T00:00:00Z")
        channel.purpose = "Building a companion"
        channel.directory = "/workspace/Studio"
        for query in ["", "cafe", "COMPANION", "studio"] {
            #expect(channelMatchesQuery(channel, query: query), "\(query)")
        }
        for query in ["internal-id", "hidden-provider", "unmatched"] {
            #expect(!channelMatchesQuery(channel, query: query), "\(query)")
        }
        channel.purpose = nil
        channel.directory = nil
        #expect(!channelMatchesQuery(channel, query: "companion"))
        #expect(channelMatchesQuery(channel, query: "cafe"))
    }
}
