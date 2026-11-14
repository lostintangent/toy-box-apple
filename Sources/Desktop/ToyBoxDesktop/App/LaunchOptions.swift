import Foundation
import ToyBoxUI

struct LaunchOptions: Equatable, Sendable {
    /// A session-only server, from `--server`.
    var server: String?
    var channelID: String?
    var appearance: AppAppearance?
    var width = 1280
    var height = 840
    #if DEBUG
    var snapshotURL: URL?
    var snapshotState: String?
    #endif
    #if TOY_BOX_BENCHMARK
    var benchmark: PerformanceBenchmark.Scenario?
    #endif

    /// A `bun run snapshot` launch, which only debug builds take.
    var isSnapshot: Bool {
        #if DEBUG
        snapshotURL != nil
        #else
        false
        #endif
    }

    /// A snapshot or benchmark launch, which keeps the menu bar, Quick Send and test digests out of
    /// what it captures or measures.
    var isAutomated: Bool {
        #if TOY_BOX_BENCHMARK
        if benchmark != nil { return true }
        #endif
        return isSnapshot
    }

    /// The server a launch override keeps to the session: `--server`, or else `TOY_BOX_SERVER_URL`.
    func sessionServer(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        server ?? environment["TOY_BOX_SERVER_URL"]
    }

    /// Isolated launches never change the user's integrations with the saved server.
    func allowsUserIntegrations(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !isAutomated && server == nil && environment["TOY_BOX_SERVER_URL"] == nil
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
            guard seen.insert(flag).inserted else {
                throw LaunchArgumentError("Repeated argument: \(flag)")
            }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw LaunchArgumentError("Missing value for \(flag)")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--server": options.server = value
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
            #if DEBUG
            case "--snapshot":
                guard !value.isEmpty, (value as NSString).pathExtension.lowercased() == "png" else {
                    throw LaunchArgumentError("--snapshot must name a PNG file")
                }
                options.snapshotURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--state":
                guard !value.isEmpty else { throw LaunchArgumentError("--state must not be empty") }
                options.snapshotState = value
            #else
            case "--snapshot", "--state":
                throw LaunchArgumentError("Only the app that bun run snapshot builds takes \(flag)")
            #endif
            #if TOY_BOX_BENCHMARK
            case "--benchmark":
                guard let scenario = PerformanceBenchmark.Scenario(rawValue: value) else {
                    throw LaunchArgumentError("--benchmark must be switch, messages, paging, scroll or key")
                }
                options.benchmark = scenario
            #else
            case "--benchmark":
                throw LaunchArgumentError("Only the app that bun run benchmark builds takes --benchmark")
            #endif
            default: break
            }
            index += 2
        }
        #if DEBUG
        if options.isSnapshot, options.channelID == nil {
            throw LaunchArgumentError("--snapshot requires --channel")
        }
        if options.snapshotState != nil, !options.isSnapshot {
            throw LaunchArgumentError("--state requires --snapshot")
        }
        #endif
        #if TOY_BOX_BENCHMARK
        if options.benchmark != nil, options.isSnapshot || options.channelID == nil {
            throw LaunchArgumentError("--benchmark requires --channel and can't take a snapshot")
        }
        #endif
        return options
    }
}

struct LaunchArgumentError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
