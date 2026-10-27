#if DEBUG && targetEnvironment(simulator)
import ActivityKit

// Simulator scaffolding only. The release's activity model waits for the design contract.
public struct FoundationActivity: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var update: Int
        public init(update: Int) { self.update = update }
    }

    public let marker: String
    public init(marker: String) { self.marker = marker }
}
#endif
