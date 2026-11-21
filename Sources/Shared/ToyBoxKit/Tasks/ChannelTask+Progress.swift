import Foundation

extension ChannelTask {
    public struct Progress: Equatable, Sendable {
        public var done: Int
        public var total: Int
    }
}

extension Array where Element == ChannelTask {
    public var progress: ChannelTask.Progress {
        ChannelTask.Progress(done: filter { $0.status == "done" }.count, total: count)
    }
}
