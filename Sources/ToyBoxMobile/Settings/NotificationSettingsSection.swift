import SwiftUI
import UserNotifications

struct NotificationSettingsSection: View {
    @Bindable var notifications: ChannelNotifications
    var registrationError: String?
    var retryRegistration: () -> Void

    var body: some View {
        Section {
            Toggle("Allow notifications", isOn: Binding(
                get: { notifications.isEnabled },
                set: { enabled in
                    if enabled { Task { await notifications.enable() } }
                    else { notifications.disable() }
                }
            ))
            .disabled(notifications.isEnabling || notifications.authorization == .denied)
            Toggle("Requests for your response", isOn: $notifications.requests)
                .disabled(!notifications.isEnabled)
            Toggle("Completed tasks", isOn: $notifications.completions)
                .disabled(!notifications.isEnabled)
            if notifications.authorization == .denied {
                Text("Notifications are turned off in Settings. Enable them there to receive requests and completions.")
                    .foregroundStyle(.secondary)
                Button("Open Settings") { Task { await notifications.openSystemSettings() } }
            }
            if let error = notifications.error {
                Text(error).foregroundStyle(.red)
            }
            if notifications.isEnabled, registrationError != nil {
                Text("Couldn't connect notifications to this server.")
                    .foregroundStyle(.red)
                Button("Try Again", action: retryRegistration)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Get notified when your team needs a response or finishes its work. Ordinary messages don't notify, and the channel you're actively reading stays quiet.")
        }
    }
}
