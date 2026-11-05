import ChannelClient
import CoreGraphics
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

    @Test func screenSocketsKeepTheDeploymentPrefixOnTheMatchingWebSocketScheme() throws {
        // A socket's request reports wss as https and ws as http, and its task traps on any other scheme.
        for (server, expected) in [("https://example.test/deploy%20root/", "https://example.test/deploy%20root/socket"),
                                   ("HTTP://[::1]:3100", "http://[::1]:3100/socket")] {
            let socket = try ChannelAPI(serverURL: server).screenSocket(id: "window:1",
                                                                         size: CGSize(width: 1279.6, height: 800.2))
            defer { socket.cancel() }
            let url = try #require(socket.originalRequest?.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(url.absoluteString.hasPrefix(expected + "?"))
            #expect(components.queryItems == [.init(name: "service", value: "screens"), .init(name: "screen", value: "window:1"),
                                              .init(name: "width", value: "1280"), .init(name: "height", value: "800")])
        }
    }
}
