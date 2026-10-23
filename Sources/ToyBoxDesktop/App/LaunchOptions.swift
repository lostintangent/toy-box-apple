import Foundation

struct LaunchOptions: Equatable, Sendable {
    var serverURL: String?
    var channelID: String?
    var appearance: AppAppearance?
    var width = 1280
    var height = 840
    var snapshotURL: URL?
    var snapshotState: String?
    var resizeBenchmark: ResizeBenchmark.Mode?
    var benchmark: PerformanceBenchmark.Scenario?

    var isSnapshot: Bool { snapshotURL != nil }

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
                   "--benchmark-resize", "--benchmark"].contains(flag) else {
                throw LaunchArgumentError("Unknown argument: \(flag)")
            }
            guard seen.insert(flag).inserted else { throw LaunchArgumentError("Repeated argument: \(flag)") }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw LaunchArgumentError("Missing value for \(flag)")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--server": options.serverURL = value
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
            case "--benchmark-resize":
                guard let mode = ResizeBenchmark.Mode(rawValue: value) else {
                    throw LaunchArgumentError("--benchmark-resize must be width, both, drag-width or drag-both")
                }
                options.resizeBenchmark = mode
            case "--benchmark":
                guard let scenario = PerformanceBenchmark.Scenario(rawValue: value) else {
                    throw LaunchArgumentError("--benchmark must be launch, switch, messages, paging or idle")
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
        if options.resizeBenchmark != nil, options.isSnapshot || options.channelID == nil {
            throw LaunchArgumentError("--benchmark-resize requires --channel and can't take a snapshot")
        }
        if options.benchmark != nil, options.isSnapshot || options.channelID == nil || options.resizeBenchmark != nil {
            throw LaunchArgumentError("--benchmark requires --channel and can't take a snapshot or run with --benchmark-resize")
        }
        return options
    }
}

struct LaunchArgumentError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
