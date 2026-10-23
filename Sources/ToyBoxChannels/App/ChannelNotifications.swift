import AppKit
import ChannelKit
import Observation
import UserNotifications

@MainActor @Observable
final class ChannelNotifications: NSObject, UNUserNotificationCenterDelegate {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var error: String?
    var onActivate: ((String, Int?, String) -> Void)?
    @ObservationIgnored private var policy = Policy()
    @ObservationIgnored private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    func enable() async -> Bool {
        error = nil
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            return granted
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func reset() {
        policy = Policy()
    }

    func update(channels: [Channel], activeChannelID: String?, serverURL: String) {
        let events = policy.events(
            channels: channels, activeChannelID: activeChannelID,
            enabled: UserDefaults.standard.bool(forKey: "notificationsEnabled"),
            requests: UserDefaults.standard.object(forKey: "requestNotifications") as? Bool != false,
            completions: UserDefaults.standard.object(forKey: "completionNotifications") as? Bool != false
        )
        for event in events {
            deliver(event: event, serverURL: serverURL)
        }
    }

    private func deliver(event: Event, serverURL: String) {
        let content = UNMutableNotificationContent()
        content.title = event.channel.name
        content.body = event.kind == .request ? "Your team is waiting for your response." : "All tasks completed."
        content.sound = .default
        content.userInfo = ["channelID": event.channel.id, "sequence": event.sequence,
                            "kind": event.kind.rawValue, "serverURL": serverURL]
        let request = UNNotificationRequest(identifier: "\(serverURL):\(event.channel.id):\(event.kind.rawValue):\(event.sequence)",
                                            content: content, trigger: nil)
        Task {
            do { try await center.add(request) }
            catch { self.error = error.localizedDescription }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["channelID"] as? String, let server = info["serverURL"] as? String else { return }
        let sequence = info["kind"] as? String == "request" ? info["sequence"] as? Int : nil
        await MainActor.run {
            onActivate?(id, sequence, server)
        }
    }

    struct Event: Equatable {
        enum Kind: String { case request, completion }
        let channel: Channel
        let sequence: Int
        let kind: Kind
    }

    struct Policy {
        private var milestones: [String: (request: Int?, completion: Int?)] = [:]
        private var hasBaseline = false

        mutating func events(channels: [Channel], activeChannelID: String?, enabled: Bool,
                             requests: Bool = true, completions: Bool = true) -> [Event] {
            let shouldNotify = hasBaseline
            hasBaseline = true
            var result: [Event] = []
            for channel in channels {
                let old = milestones[channel.id]
                milestones[channel.id] = (channel.requestSequence, channel.completedSequence)
                guard shouldNotify, enabled, channel.id != activeChannelID else { continue }
                if let sequence = channel.requestSequence, old?.request != sequence, requests {
                    result.append(Event(channel: channel, sequence: sequence, kind: .request))
                } else if let sequence = channel.completedSequence, sequence > channel.seenThrough,
                          old?.completion != sequence, completions {
                    result.append(Event(channel: channel, sequence: sequence, kind: .completion))
                }
            }
            return result
        }
    }
}
