import ChannelClient
import Foundation
import SwiftUI

/// The catalog connection as the sidebar footer reports it.
public enum SidebarConnection: Equatable, Sendable {
    case connecting, connected, reconnecting, unreachable

    public init(loaded: Bool, failing: Bool, fatal: Bool) {
        if fatal || (failing && !loaded) { self = .unreachable }
        else if failing { self = .reconnecting }
        else { self = loaded ? .connected : .connecting }
    }

    public static func isFatal(_ failure: (any Error)?) -> Bool {
        guard case .http(let status, _)? = failure as? ChannelAPIError else { return false }
        return status == 401 || status == 403
    }

    public var dot: Color {
        switch self {
        case .connecting: .secondary
        case .connected: .green
        case .reconnecting: .orange
        case .unreachable: .red
        }
    }

    public var heading: String? {
        switch self {
        case .connecting, .connected: nil
        case .reconnecting: "Channels may be out of date"
        case .unreachable: "Can't connect to Toy Box"
        }
    }

    public var verb: String {
        switch self {
        case .connecting: "Connecting to"
        case .connected: "Connected to"
        case .reconnecting: "Reconnecting to"
        case .unreachable: "Can't connect to"
        }
    }

    public var accessibilityValue: String {
        switch self {
        case .connecting: "connecting"
        case .connected: "connected"
        case .reconnecting: "reconnecting"
        case .unreachable: "can't connect"
        }
    }

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
