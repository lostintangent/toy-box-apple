import ActivityKit
import ChannelKit
import Foundation

@MainActor
protocol ChannelActivitySession: AnyObject {
    var id: String { get }
    var attributes: ChannelActivityAttributes { get }
    var content: ChannelActivityAttributes.ContentState { get }
    var isActive: Bool { get }
    var pushToken: Data? { get }
    var pushTokenUpdates: AsyncStream<Data> { get }
    var activeUpdates: any AsyncSequence<Bool, Never> { get }
    func end(_ state: ChannelActivityAttributes.ContentState) async
}

@MainActor
struct ChannelActivityClient {
    var activities: () -> [any ChannelActivitySession]
    var request: (ChannelActivityAttributes, ChannelActivityAttributes.ContentState) throws -> any ChannelActivitySession

    static var system: Self {
        Self(activities: {
            Activity<ChannelActivityAttributes>.activities.map(SystemChannelActivity.init)
        }, request: { attributes, state in
            SystemChannelActivity(try Activity.request(
                attributes: attributes, content: ActivityContent(state: state, staleDate: state.staleDate),
                pushType: .token
            ))
        })
    }
}

@MainActor
private final class SystemChannelActivity: ChannelActivitySession {
    private let activity: Activity<ChannelActivityAttributes>

    init(_ activity: Activity<ChannelActivityAttributes>) { self.activity = activity }

    var id: String { activity.id }
    var attributes: ChannelActivityAttributes { activity.attributes }
    var content: ChannelActivityAttributes.ContentState { activity.content.state }
    var isActive: Bool { activity.activityState == .active || activity.activityState == .stale }
    var pushToken: Data? { activity.pushToken }

    var pushTokenUpdates: AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                for await token in activity.pushTokenUpdates {
                    if Task.isCancelled { break }
                    continuation.yield(token)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var activeUpdates: any AsyncSequence<Bool, Never> {
        activity.activityStateUpdates.map {
            $0 == .active || $0 == .stale
        }
    }

    func end(_ state: ChannelActivityAttributes.ContentState) async {
        await SystemActivityUpdates.end(id: id, state: state)
    }
}

private enum SystemActivityUpdates {
    @concurrent static func end(id: String, state: ChannelActivityAttributes.ContentState) async {
        guard let activity = Activity<ChannelActivityAttributes>.activities.first(where: { $0.id == id })
        else { return }
        await activity.end(ActivityContent(state: state, staleDate: nil),
                           dismissalPolicy: .immediate)
    }
}
