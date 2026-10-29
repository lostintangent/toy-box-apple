import ChannelClient
import Foundation
import SwiftUI

/// How the sidebar footer shows the catalog's phase on both apps. See Connections in docs/spec.md.
/// A failure keeps the rows and shows orange, unless no rows have loaded or the server refused this
/// app, which shows red.
public struct SidebarFooter: Equatable {
    public let dot: Color
    public let heading: String?
    /// Precedes the server in the footer's help.
    public let verb: String
    public let accessibilityValue: String

    /// A nil phase is a server address the app can't use, so there is no catalog to ask.
    public init(phase: ChannelCatalogPhase?, isLoaded: Bool) {
        switch phase {
        case .connecting?: self.init(.secondary, nil, "Connecting to", "connecting")
        case .connected?: self.init(.green, nil, "Connected to", "connected")
        case .failed(let error)? where isLoaded && !Self.isRefusal(error):
            self.init(.orange, "Channels may be out of date", "Reconnecting to", "reconnecting")
        case .failed?, nil: self.init(.red, "Can't connect to Toy Box", "Can't connect to", "can't connect")
        }
    }

    private init(_ dot: Color, _ heading: String?, _ verb: String, _ accessibilityValue: String) {
        self.dot = dot
        self.heading = heading
        self.verb = verb
        self.accessibilityValue = accessibilityValue
    }

    private static func isRefusal(_ error: any Error) -> Bool {
        guard case .http(let status, _)? = error as? ChannelAPIError else { return false }
        return status == 401 || status == 403
    }

    /// The server as the footer and menu bar name it: its host, and a port that isn't the default.
    public static func server(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else {
            return url
        }
        let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port = components.port else { return name }
        let standard = ["http": 80, "https": 443][components.scheme?.lowercased() ?? ""]
        return port == standard ? name : "\(name):\(port)"
    }
}
