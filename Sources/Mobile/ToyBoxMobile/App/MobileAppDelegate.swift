import ChannelClient
import Observation
import UIKit

@MainActor
final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()
    private var sendingTask = UIBackgroundTaskIdentifier.invalid

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        model.notifications.installDelegate()
        ChannelIntents.register(model)
        holdBackgroundTimeWhileSending()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.notifications.receivedDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        model.notifications.failedToReceiveDeviceToken(error)
    }

    /// While the outbox has a message on its way, the app keeps running in the background, so a Lock
    /// Screen reply or a send made just before leaving finishes without the app open. One that's
    /// still sending when the time runs out goes out at the next launch.
    private func holdBackgroundTimeWhileSending() {
        let isDelivering = withObservationTracking { model.outbox.isDelivering } onChange: { [weak self] in
            Task { @MainActor in self?.holdBackgroundTimeWhileSending() }
        }
        if isDelivering, sendingTask == .invalid {
            sendingTask = UIApplication.shared.beginBackgroundTask(withName: "Sending messages") { [weak self] in
                self?.endBackgroundTime()
            }
        } else if !isDelivering {
            endBackgroundTime()
        }
    }

    private func endBackgroundTime() {
        guard sendingTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(sendingTask)
        sendingTask = .invalid
    }
}
