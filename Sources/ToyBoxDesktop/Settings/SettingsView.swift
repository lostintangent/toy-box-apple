import AppKit
import ChannelClient
import ChannelIntelligence
import SwiftUI
import ToyBoxUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.channelIntelligence) private var intelligence
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage(MenuBarVisibility.key) private var menuBarVisibility: MenuBarVisibility = .whenActive
    @AppStorage(TranscriptIntelligenceSettings.summarizesNewMessages) private var summarizesNewMessages = true
    @AppStorage(TranscriptIntelligenceSettings.describesImages) private var describesImages = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("requestNotifications") private var requestNotifications = true
    @AppStorage("completionNotifications") private var completionNotifications = false
    @AppStorage(DockAttention.enabledKey) private var bounceDockForRequests = false
    @AppStorage(MorningDigest.enabledKey) private var morningDigestEnabled = true
    @AppStorage(MorningDigest.timeKey) private var morningDigestMinutes = 480
    @ViewState private var connection = ServerConnectionProbe()
    @ViewState private var configurationFailure: String?
    @ViewState private var isEnabling = false
    @ViewState private var confirmsServerChange = false
    /// Read on appear and whenever the app becomes active, since the service can't be observed.
    @ViewState private var intelligenceAvailability: IntelligenceAvailability?

    var body: some View {
        TabView {
            fitted(general).tabItem { Label("General", systemImage: "gearshape") }
            fitted(notifications).tabItem { Label("Notifications", systemImage: "bell") }
        }
        .onAppear {
            connection.address = model.serverURL
            intelligenceAvailability = intelligence.availability
            model.openAtLogin.refresh()
        }
        .onDisappear { connection.cancel() }
        .onChange(of: connection.address) { _, _ in configurationFailure = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            intelligenceAvailability = intelligence.availability
            model.openAtLogin.refresh()
        }
        .task {
            await model.notifications.refreshAuthorization()
            if model.notifications.authorization == .denied { notificationsEnabled = false }
        }
        .onChange(of: model.notifications.authorization) { _, status in
            if status == .denied { notificationsEnabled = false }
        }
        .confirmationDialog("Switch Toy Box servers?", isPresented: $confirmsServerChange) {
            Button("Switch Server") { useServer() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Live connections to \(model.serverURL) will close. Drafts stay saved separately for each server.")
        }
    }

    private var general: some View {
        @Bindable var connection = connection
        return Form {
            Section {
                TextField("Server URL", text: $connection.address)
                    .textContentType(.URL)
                    .onSubmit { requestServerChange() }
                Text("Use an HTTP or HTTPS URL, including any server path prefix.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(connection.isTesting ? "Connecting..." : "Test Connection") {
                        configurationFailure = nil
                        connection.start()
                    }
                        .disabled(connection.isTesting || validationError != nil)
                    if connection.isTesting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Use Server") { requestServerChange() }
                        .disabled(connection.address == model.serverURL || validationError != nil || connection.isTesting)
                }
                if let validationError {
                    errorLabel(validationError)
                }
                switch connection.phase {
                case .connected(let url, let count):
                    Label(Self.connectionSummary(serverURL: url.absoluteString, channelCount: count),
                          systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                case .failed(let address, let error):
                    errorLabel("Couldn't connect to \(address): \(error.localizedDescription)")
                case .idle, .testing:
                    EmptyView()
                }
                if let configurationFailure {
                    errorLabel(configurationFailure)
                }
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { value in Text(value.title).tag(value) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("Show in menu bar", selection: $menuBarVisibility) {
                    ForEach(MenuBarVisibility.allCases) { value in Text(value.title).tag(value) }
                }
                .pickerStyle(.menu)
            } footer: {
                footer("When Active shows the icon while agents are working or a channel is waiting for you.")
            }
            Section {
                Toggle("Open at Login", isOn: Binding(
                    get: { model.openAtLogin.isEnabled },
                    set: { enabled in Task { await model.openAtLogin.setEnabled(enabled) } }
                ))
                .accessibilityLabel("Open at Login")
                .disabled(!model.openAtLogin.isAvailable || model.openAtLogin.isUpdating)
                if model.openAtLogin.isUpdating {
                    ProgressView("Updating Login Items…").controlSize(.small)
                }
                if model.openAtLogin.requiresApproval {
                    Label("Approval Required", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.openAtLogin.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.openAtLogin.isAvailable,
                   model.openAtLogin.statusMessage != nil {
                    HStack {
                        Button("Open Login Items…") { model.openAtLogin.openSettings() }
                        if model.openAtLogin.requiresApproval {
                            Button("Cancel Request") {
                                Task { await model.openAtLogin.setEnabled(false) }
                            }
                        }
                    }
                    .disabled(model.openAtLogin.isUpdating)
                }
                if let error = model.openAtLogin.error { errorLabel(error) }
            } footer: {
                footer("Keep Toy Box ready in the Dock and menu bar without opening a window.")
            }
            Section {
                HStack {
                    Text("Quick Send shortcut")
                    Spacer()
                    QuickSendShortcutRecorder(controller: model.quickSend)
                        .frame(width: 132, height: 28)
                        .disabled(!model.quickSend.isEnabled)
                    Button {
                        model.quickSend.setShortcut(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 28, minHeight: 28)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear Quick Send shortcut")
                    .help("Clear Quick Send shortcut")
                    .disabled(model.quickSend.shortcut == nil)
                }
                if let error = model.quickSend.error {
                    errorLabel(error)
                }
            } footer: {
                footer("Send a message from any app. Clearing the shortcut keeps Quick Send available in the menus.")
            }
            intelligenceSection
            updatesSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var updatesSection: some View {
        if model.updates.isRunning {
            @Bindable var updates = model.updates
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                Toggle("Automatically download and install updates", isOn: $updates.automaticallyDownloadsUpdates)
                    .disabled(!updates.automaticallyChecksForUpdates || !updates.allowsAutomaticUpdates)
            }
        }
    }

    /// The on-device features. When the model can't run here, the toggles keep their values and one
    /// footer says why in place of their descriptions.
    private var intelligenceSection: some View {
        let unavailable: IntelligenceUnavailableReason? = if case .unavailable(let reason) = intelligenceAvailability {
            reason
        } else { nil }
        return Section {
            Toggle(isOn: $summarizesNewMessages) {
                Text("Summarize new messages")
                if unavailable == nil {
                    Text("When you return to a busy channel, a summary appears above the new messages. Made on this Mac.")
                }
            }
            .disabled(unavailable != nil)
            Toggle(isOn: $describesImages) {
                Text("Describe images for VoiceOver")
                if unavailable == nil {
                    Text("While VoiceOver is running, images get descriptions made on this Mac.")
                }
            }
            .disabled(unavailable != nil)
        } footer: {
            if let unavailable {
                HStack(alignment: .firstTextBaseline) {
                    footer(Self.unavailableText(unavailable))
                    Spacer()
                    if unavailable == .appleIntelligenceNotEnabled {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
    }

    static func unavailableText(_ reason: IntelligenceUnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This Mac doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings to use these."
        case .modelNotReady: "Apple Intelligence is getting ready. Try again later."
        case .unsupportedLanguage: "Apple Intelligence doesn't support your Mac's language yet."
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// Each pane is as tall as its content, so the window grows to fit rather than scrolling.
    private func fitted(_ pane: some View) -> some View {
        pane.scrollDisabled(true).frame(width: 540).fixedSize(horizontal: false, vertical: true)
    }

    private var notifications: some View {
        Form {
            Section {
                Text("Get notified when your team needs a response or finishes its work. Ordinary messages don't notify, and the channel you're actively reading stays quiet.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Allow notifications", isOn: Binding(
                    get: { notificationsEnabled },
                    set: { enabled in
                        if !enabled { notificationsEnabled = false }
                        else {
                            isEnabling = true
                            Task {
                                notificationsEnabled = await model.notifications.enable()
                                isEnabling = false
                            }
                        }
                    }
                ))
                .accessibilityLabel("Allow notifications")
                .disabled(isEnabling || model.notifications.authorization == .denied)
                Toggle("Requests for your response", isOn: $requestNotifications)
                    .accessibilityLabel("Requests for your response").disabled(!notificationsEnabled)
                Toggle("Completed tasks", isOn: $completionNotifications)
                    .accessibilityLabel("Completed tasks").disabled(!notificationsEnabled)
            }
            Section {
                Toggle("Bounce Dock icon for new requests", isOn: $bounceDockForRequests)
                    .accessibilityLabel("Bounce Dock icon for new requests")
            } footer: {
                footer("Bounce once when a new request arrives while you're using another app.")
            }
            Section {
                Toggle("Morning digest", isOn: $morningDigestEnabled)
                    .accessibilityLabel("Morning digest")
                    .disabled(!notificationsEnabled)
                DatePicker("Deliver at", selection: digestTime,
                           in: digestTimeRange,
                           displayedComponents: .hourAndMinute)
                    .accessibilityLabel("Deliver at")
                    .disabled(!notificationsEnabled || !morningDigestEnabled)
                if MorningDigest.canTest(bundleID: Bundle.main.bundleIdentifier,
                                         options: model.launchOptions, server: model.serverURL) {
                    Button("Send Test Digest") { Task { await model.morningDigest?.sendTest() } }
                        .disabled(model.morningDigest?.isRunning == true)
                }
            } footer: {
                footer("A daily recap of activity from your teams. Made on this Mac. If your Mac is asleep, it arrives when you return before noon.")
            }
            if model.notifications.authorization == .denied {
                Section {
                    Text("Notifications are turned off in System Settings. Enable them there to receive requests and completions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            if let error = model.notifications.error {
                errorLabel(error)
            }
            if let error = model.morningDigest?.error { errorLabel(error) }
        }
        .formStyle(.grouped)
    }

    private var digestTimeRange: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(bySettingHour: 11, minute: 59, second: 0, of: start) ?? start
        return start...end
    }

    private var digestTime: Binding<Date> {
        Binding(
            get: {
                let minutes = (0..<720).contains(morningDigestMinutes) ? morningDigestMinutes : 480
                return Calendar.current.date(bySettingHour: minutes / 60,
                                             minute: minutes % 60, second: 0, of: .now) ?? .now
            },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                morningDigestMinutes = min(719, (parts.hour ?? 8) * 60 + (parts.minute ?? 0))
            }
        )
    }

    private func errorLabel(_ error: String) -> some View {
        Label {
            Text(error).foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        }
        .font(.caption).textSelection(.enabled)
    }

    private var validationError: String? {
        connection.validationError
    }

    private func requestServerChange() {
        guard validationError == nil, connection.address != model.serverURL else { return }
        confirmsServerChange = true
    }

    private func useServer() {
        model.configure(serverURL: connection.address)
        connection.address = model.serverURL
        connection.cancel()
        configurationFailure = model.configurationError
    }

    static func connectionSummary(serverURL: String, channelCount: Int) -> String {
        let noun = channelCount == 1 ? "channel" : "channels"
        return "Connected to \(serverURL). \(channelCount) \(noun) available."
    }
}
