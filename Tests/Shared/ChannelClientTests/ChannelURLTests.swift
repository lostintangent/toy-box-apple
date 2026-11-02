import ChannelClient
import Foundation
import Testing

struct ChannelURLTests {
    @Test func browserLinksKeepTheDeploymentPrefixAndJSONChannelSelection() throws {
        let api = try ChannelAPI(serverURL: "https://example.test/deploy%20root/")
        let channelID = "channel/&?%"
        let url = try #require(api.channelURL(channelID: channelID))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/deploy%20root/")
        let value = try #require(components.queryItems?.first { $0.name == "channels" }?.value)
        #expect(try JSONDecoder().decode([String].self, from: Data(value.utf8)) == [channelID])
        #expect(components.queryItems?.count == 1)
    }
}
