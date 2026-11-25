import Foundation
import Thrush
import ToyBoxClient
import ToyBoxKit

/// This device's shell on each server, kept while the app runs. Closing the terminal or picking
/// another server only leaves a shell, and its server keeps it for 30 seconds, so coming back
/// resumes it.
@MainActor
final class TerminalShells {
    private let defaults: UserDefaults
    private var shells: [String: TerminalShell] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The shell on this server, under the client ID this device saved for it.
    func shell(on api: ChannelAPI) -> TerminalShell {
        let server = ChannelTarget.normalizedServer(api.baseURL)
        if let shell = shells[server] { return shell }
        let shell = TerminalShell(clientID: api.terminalClientID(in: defaults)) { id, size in
            api.terminalSocket(clientID: id, columns: size.columns, rows: size.rows)
        }
        shells[server] = shell
        return shell
    }

    /// Lets go of a server's shell as the server leaves the list, so the server ends it once its
    /// 30 seconds pass.
    func forget(_ server: String) {
        shells[ChannelTarget.normalizedServer(server) ?? server] = nil
    }
}
