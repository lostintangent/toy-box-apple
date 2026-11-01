import Foundation

public struct ChannelTrayProjection: Equatable, Sendable {
    public let artifacts: [ChannelArtifact]
    public let taskProgress: TaskProgress
    public let preview: ChannelPreview?
    public var hasTasks: Bool { taskProgress.total > 0 }
    public var isVisible: Bool { !artifacts.isEmpty || hasTasks || preview != nil }

    public init(artifacts: [ChannelArtifact], tasks: [ChannelTask], preview: ChannelPreview?) {
        self.artifacts = channelArtifactsNewestFirst(artifacts)
        taskProgress = channelTasksProgress(tasks)
        self.preview = preview
    }
}
