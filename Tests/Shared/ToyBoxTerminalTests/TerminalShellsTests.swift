import Foundation
import Testing
import Thrush
import ToyBoxClient
import ToyBoxTerminal

@MainActor
struct TerminalShellsTests {
    @Test func reopeningAfterAnExitStartsAFreshShell() async throws {
        let suite = "tbm-terminal-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = try ChannelAPI(baseURL: #require(URL(string: "http://127.0.0.1:9")))
        let shells = TerminalShells(defaults: defaults)
        let first = shells.shell(on: api)

        shells.leave(first)
        #expect(shells.shell(on: api) === first)

        // It never attached, so closing ends it here, as `exit` would.
        try? await first.close()
        #expect(first.hasEnded)
        shells.leave(first)
        let fresh = shells.shell(on: api)
        #expect(fresh !== first && !fresh.hasEnded)
    }
}
