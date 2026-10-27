import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

public struct ChannelActivityAttributes: Codable, Hashable, Sendable {
    public var channelID: String
    public var channelName: String
    public var registrationID: String

    public init(channelID: String, channelName: String, registrationID: String) {
        self.channelID = channelID
        self.channelName = channelName
        self.registrationID = registrationID
    }

    public struct WorkingAgent: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var avatar: AgentAvatar?

        public init(_ agent: ChannelAgent) {
            id = agent.id
            name = agent.name
            avatar = agent.avatar
        }
    }

    public enum Ending: String, Codable, Sendable {
        case completed, stopped, expired, channelDeleted, serverChanged, tasksRemoved
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public static let freshnessInterval: TimeInterval = 15 * 60
        public var workingAgents: [WorkingAgent]
        public var tasksDone: Int
        public var tasksTotal: Int
        public var waitingRequestSequence: Int?
        public var updatedAt: Date
        public var ending: Ending?

        public init(workingAgents: [WorkingAgent] = [], tasksDone: Int, tasksTotal: Int,
                    waitingRequestSequence: Int? = nil, updatedAt: Date, ending: Ending? = nil) {
            self.workingAgents = workingAgents
            self.tasksDone = tasksDone
            self.tasksTotal = tasksTotal
            self.waitingRequestSequence = waitingRequestSequence
            self.updatedAt = updatedAt
            self.ending = ending
        }

        public var staleDate: Date? {
            ending == nil ? updatedAt.addingTimeInterval(Self.freshnessInterval) : nil
        }

        private enum CodingKeys: String, CodingKey {
            case workingAgents, tasksDone, tasksTotal, waitingRequestSequence, updatedAt, ending
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(workingAgents: try values.decode([WorkingAgent].self, forKey: .workingAgents),
                      tasksDone: try values.decode(Int.self, forKey: .tasksDone),
                      tasksTotal: try values.decode(Int.self, forKey: .tasksTotal),
                      waitingRequestSequence: try values.decodeIfPresent(Int.self, forKey: .waitingRequestSequence),
                      updatedAt: Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .updatedAt)),
                      ending: try values.decodeIfPresent(Ending.self, forKey: .ending))
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(workingAgents, forKey: .workingAgents)
            try values.encode(tasksDone, forKey: .tasksDone)
            try values.encode(tasksTotal, forKey: .tasksTotal)
            try values.encodeIfPresent(waitingRequestSequence, forKey: .waitingRequestSequence)
            try values.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
            try values.encodeIfPresent(ending, forKey: .ending)
        }
    }
}

#if os(iOS) && canImport(ActivityKit)
extension ChannelActivityAttributes: ActivityAttributes {}
#endif
