import Foundation

public struct ChannelTray: Equatable, Sendable {
    public let artifacts: [ChannelArtifact]
    public let taskProgress: ChannelTask.Progress
    public let preview: ChannelPreview?
    public var hasTasks: Bool { taskProgress.total > 0 }
    public var isVisible: Bool { !artifacts.isEmpty || hasTasks || preview != nil }

    public init(artifacts: [ChannelArtifact], tasks: [ChannelTask], preview: ChannelPreview?) {
        self.artifacts = artifacts.newestFirst
        taskProgress = tasks.progress
        self.preview = preview
    }
}
