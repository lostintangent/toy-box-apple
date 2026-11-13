import Foundation
import ToyBoxUI

struct LaunchOptions: Equatable, Sendable {
    /// Session-only servers in sidebar order, from each `--server`.
    var servers: [String] = []
    var channelID: String?
    var appearance: AppAppearance?
    var width = 1280
    var height = 840
    var snapshotURL: URL?
    var snapshotState: String?
    var benchmark: PerformanceBenchmark.Scenario?

    var isSnapshot: Bool { snapshotURL != nil }

    /// The servers a launch override keeps to the session: each `--server`, or else
    /// `TOY_BOX_SERVER_URL`.
    func sessionServers(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        servers.isEmpty ? environment["TOY_BOX_SERVER_URL"].map { [$0] } ?? [] : servers
    }

    /// Isolated launches never change the user's integrations with the saved server.
    func allowsUserIntegrations(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !isSnapshot && benchmark == nil
            && servers.isEmpty && environment["TOY_BOX_SERVER_URL"] == nil
    }

    static func parse(_ arguments: [String]) throws -> LaunchOptions {
        var options = LaunchOptions()
        var seen: Set<String> = []
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag.hasPrefix("-NS") || flag.hasPrefix("-Apple") {
                index += 2
                continue
            }
            guard ["--server", "--channel", "--appearance", "--size", "--snapshot", "--state",
                   "--benchmark"].contains(flag) else {
                throw LaunchArgumentError("Unknown argument: \(flag)")
            }
            guard flag == "--server" || seen.insert(flag).inserted else {
                throw LaunchArgumentError("Repeated argument: \(flag)")
            }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw LaunchArgumentError("Missing value for \(flag)")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--server": options.servers.append(value)
            case "--channel":
                guard !value.isEmpty else { throw LaunchArgumentError("--channel must not be empty") }
                options.channelID = value
            case "--appearance":
                guard let appearance = AppAppearance(rawValue: value), appearance != .system else {
                    throw LaunchArgumentError("--appearance must be light or dark")
                }
                options.appearance = appearance
            case "--size":
                let parts = value.split(separator: "x", omittingEmptySubsequences: false)
                guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
                      (760...4096).contains(width), (560...4096).contains(height) else {
                    throw LaunchArgumentError("--size must be WIDTHxHEIGHT, between 760x560 and 4096x4096 points")
                }
                options.width = width
                options.height = height
            case "--snapshot":
                guard !value.isEmpty, (value as NSString).pathExtension.lowercased() == "png" else {
                    throw LaunchArgumentError("--snapshot must name a PNG file")
                }
                options.snapshotURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--state":
                guard !value.isEmpty else { throw LaunchArgumentError("--state must not be empty") }
                options.snapshotState = value
            case "--benchmark":
                guard let scenario = PerformanceBenchmark.Scenario(rawValue: value) else {
                    throw LaunchArgumentError("--benchmark must be switch, messages, paging, scroll or key")
                }
                options.benchmark = scenario
            default: break
            }
            index += 2
        }
        if options.isSnapshot, options.channelID == nil {
            throw LaunchArgumentError("--snapshot requires --channel")
        }
        if options.snapshotState != nil, !options.isSnapshot {
            throw LaunchArgumentError("--state requires --snapshot")
        }
        if options.benchmark != nil, options.isSnapshot || options.channelID == nil {
            throw LaunchArgumentError("--benchmark requires --channel and can't take a snapshot")
        }
        return options
    }
}

struct LaunchArgumentError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
