import Foundation

public func channelArtifactsNewestFirst(_ artifacts: [ChannelArtifact]) -> [ChannelArtifact] {
    artifacts
        .map { (artifact: $0, date: $0.sharedAt.flatMap({ try? Date($0, strategy: .iso8601) })) }
        .sorted {
            switch ($0.date, $1.date) {
            case let (left?, right?) where left != right: left > right
            case (_?, nil): true
            case (nil, _?): false
            default: false
            }
        }
        .map(\.artifact)
}
