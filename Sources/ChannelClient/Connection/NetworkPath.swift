import Dispatch
import Network

/// What reconnecting needs to know about the device's network: whether it reaches anything, and
/// through which interface.
public struct NetworkPath: Equatable, Sendable {
    public var isSatisfied: Bool
    /// The preferred interface's name, such as `en0`, so a move from Wi-Fi to cellular reads as a
    /// change even though the path stays satisfied.
    public var interface: String?

    public init(isSatisfied: Bool, interface: String?) {
        self.isSatisfied = isSatisfied
        self.interface = interface
    }

    /// Whether a channel stuck on `previous` should try again on this path. The first path is only
    /// where things stand, so it changes nothing.
    func isReturn(from previous: NetworkPath?) -> Bool {
        guard let previous, isSatisfied else { return false }
        return !previous.isSatisfied || previous.interface != interface
    }
}

/// Where a catalog hears about the network while it polls. `.system` follows `NWPathMonitor`,
/// whose first report is the current path, and tests pass a stream they drive.
public struct NetworkPathSource: Sendable {
    public let paths: @Sendable () -> AsyncStream<NetworkPath>

    public init(paths: @escaping @Sendable () -> AsyncStream<NetworkPath>) {
        self.paths = paths
    }

    public static let system = NetworkPathSource {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(.init(isSatisfied: path.status == .satisfied,
                                         interface: path.availableInterfaces.first?.name))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "dev.toybox.network-path", qos: .utility))
        }
    }
}
