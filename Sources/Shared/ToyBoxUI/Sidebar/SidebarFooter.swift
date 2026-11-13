import ChannelClient
import Foundation
import SwiftUI

/// How the sidebar footer shows the catalog's phase on both apps. See Connections in docs/spec.md.
/// A failure keeps the rows and shows orange, unless no rows have loaded or the server refused this
/// app, which shows red.
public struct SidebarFooter: Equatable {
    public let dot: Color
    /// Precedes the server in the footer's help.
    public let verb: String
    public let accessibilityValue: String

    /// The rows stay while the catalog reconnects on its own.
    public var isReconnecting: Bool { dot == .orange }
    /// An orange or red dot.
    public var isFailing: Bool { dot == .orange || dot == .red }

    /// A nil phase is a server address the app can't use, so there is no catalog to ask.
    public init(phase: ChannelCatalogPhase?, isLoaded: Bool) {
        switch phase {
        case .connecting?: self.init(.secondary, "Connecting to", "connecting")
        case .connected?: self.init(.green, "Connected to", "connected")
        case .failed(let error)? where isLoaded && !Self.isRefusal(error): self.init(.orange, "Reconnecting to", "reconnecting")
        case .failed?, nil: self.init(.red, "Can't connect to", "can't connect")
        }
    }

    private init(_ dot: Color, _ verb: String, _ accessibilityValue: String) {
        self.dot = dot
        self.verb = verb
        self.accessibilityValue = accessibilityValue
    }

    private static func isRefusal(_ error: any Error) -> Bool {
        guard case .http(let status, _)? = error as? ChannelAPIError else { return false }
        return status == 401 || status == 403
    }

    /// The server as the footer and menu bar name it: its host, and a port that isn't the default.
    public static func server(_ url: String) -> String { ChannelCatalogStore.Saved.name(of: url) }

    /// Red, then orange, then the first load's gray, then green.
    fileprivate var severity: Int {
        switch dot {
        case .red: 3
        case .orange: 2
        case .green: 0
        default: 1
        }
    }
}

extension SidebarFooter {
    /// How the Mac footer's status line counts the servers and sums up their health. See Several
    /// servers in docs/spec.md.
    public struct Summary: Equatable {
        public let count: Int
        /// The least healthy server's status, which never spins, since each header shows its own load.
        public let footer: SidebarFooter
        /// The least healthy server's name, or nil when every server is connected.
        public let server: String?
        /// The least healthy server's readable failure, while it has one.
        public let failure: String?
        /// The help's first line, which VoiceOver reads too: the least healthy server, or with every
        /// server connected, the only one's name or how many there are.
        public let status: String

        /// The servers in Settings' order, where the first of the least healthy wins.
        public init(servers: [(name: String, footer: SidebarFooter, failure: String?)]) {
            let worst = servers.max { $0.footer.severity < $1.footer.severity }
            count = servers.count
            footer = worst?.footer ?? SidebarFooter(phase: .connecting, isLoaded: false)
            server = worst?.footer.severity == 0 ? nil : worst?.name
            failure = server == nil ? nil : worst?.failure
            if let server {
                status = "\(footer.verb) \(server)"
            } else if count == 1, let only = servers.first {
                status = "Connected to \(only.name)"
            } else {
                status = "Connected to \(count) servers"
            }
        }

        @MainActor public init(catalogs: [ChannelCatalogStore]) {
            self.init(servers: catalogs.map {
                ($0.name, SidebarFooter(phase: $0.phase, isLoaded: $0.isLoaded), $0.phase.message)
            })
        }

        /// What the status line shows, which never names a host.
        public var title: String { count == 1 ? "1 server" : "\(count) servers" }
    }
}
