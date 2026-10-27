import SwiftUI
import TipKit

struct NotificationPermissionTip: Tip {
    var title: Text { Text("Get notified when your team needs you") }
    var message: Text? { Text("Receive requests and completed-task alerts. Ordinary messages stay quiet.") }
    var actions: [Action] { [Action(id: "enable", title: "Turn On Notifications")] }
}
