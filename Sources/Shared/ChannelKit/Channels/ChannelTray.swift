import Foundation

public struct ChannelTray: Equatable, Sendable {
    public let artifacts: [ChannelArtifact]
    public let taskProgress: ChannelTask.Progress
    public let preview: ChannelPreview?
    public let bookmarkCount: Int
    public var hasTasks: Bool { taskProgress.total > 0 }
    public var isVisible: Bool { !artifacts.isEmpty || hasTasks || preview != nil || bookmarkCount > 0 }

    public init(artifacts: [ChannelArtifact], tasks: [ChannelTask], preview: ChannelPreview?,
                bookmarkCount: Int = 0) {
        self.artifacts = artifacts.newestFirst
        taskProgress = tasks.progress
        self.preview = preview
        self.bookmarkCount = bookmarkCount
    }
}
