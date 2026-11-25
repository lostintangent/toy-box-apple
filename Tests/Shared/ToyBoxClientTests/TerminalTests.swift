import Foundation
import Testing
import ToyBoxClient

struct TerminalTests {
    @Test func eachServerKeepsOneShellOnThisDevice() throws {
        let suite = "tbm-terminal-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let studio = try ChannelAPI(serverURL: "studio.example:3100").terminalClientID(in: defaults)
        #expect(!studio.isEmpty)
        #expect(try ChannelAPI(serverURL: "https://studio.example:3100").terminalClientID(in: defaults) == studio)
        #expect(try ChannelAPI(serverURL: "mini.example").terminalClientID(in: defaults) != studio)
    }

    @Test func aTerminalSocketNamesItsShellAndGrid() throws {
        let socket = try ChannelAPI(serverURL: "https://example.test/deploy%20root/")
            .terminalSocket(clientID: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", columns: 45, rows: 30)
        defer { socket.cancel() }
        let url = try #require(socket.originalRequest?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.absoluteString.hasPrefix("https://example.test/deploy%20root/socket?"))
        #expect(components.queryItems == [.init(name: "service", value: "terminal"),
                                          .init(name: "clientId", value: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
                                          .init(name: "cols", value: "45"), .init(name: "rows", value: "30")])
        #expect(socket.state == .suspended, "The connection resumes the socket itself.")
    }
}
