import AppKit
import ChannelClient
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("requestNotifications") private var requestNotifications = true
    @AppStorage("completionNotifications") private var completionNotifications = true
    @ViewState private var serverURL = ""
    @ViewState private var result: String?
    @ViewState private var resultIsError = false
    @ViewState private var isTesting = false
    @ViewState private var isEnabling = false
    @ViewState private var confirmsServerChange = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            notifications.tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 540, height: 380)
        .onAppear { serverURL = model.serverURL }
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
        Form {
            Section {
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
                    .onSubmit { requestServerChange() }
                Text("Use an HTTP or HTTPS URL, including any server path prefix.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(isTesting ? "Connecting..." : "Test Connection") { testConnection() }
                        .disabled(isTesting || validationError != nil)
                    if isTesting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Use Server") { requestServerChange() }
                        .disabled(serverURL == model.serverURL || validationError != nil || isTesting)
                }
                if let validationError {
                    errorLabel(validationError)
                }
                if let result {
                    if resultIsError {
                        errorLabel(result)
                    } else {
                        Label(result, systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { value in Text(value.title).tag(value) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    private var notifications: some View {
        Form {
            Section {
                Text("Get notified when your team needs a response or finishes its work. Ordinary messages don't notify, and the channel you're actively reading stays quiet.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Enable Notifications", isOn: Binding(
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
                .accessibilityLabel("Enable Notifications")
                .disabled(isEnabling || model.notifications.authorization == .denied)
                Toggle("Requests for your response", isOn: $requestNotifications)
                    .accessibilityLabel("Requests for your response").disabled(!notificationsEnabled)
                Toggle("Completed tasks", isOn: $completionNotifications)
                    .accessibilityLabel("Completed tasks").disabled(!notificationsEnabled)
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
        }
        .formStyle(.grouped)
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
        do { _ = try ChannelAPI(serverURL: serverURL); return nil }
        catch { return error.localizedDescription }
    }

    private func requestServerChange() {
        guard validationError == nil, serverURL != model.serverURL else { return }
        confirmsServerChange = true
    }

    private func useServer() {
        model.configure(serverURL: serverURL)
        serverURL = model.serverURL
        result = model.configurationError
        resultIsError = result != nil
    }

    private func testConnection() {
        let testingURL = serverURL
        result = nil
        isTesting = true
        Task {
            defer { isTesting = false }
            do {
                let catalog = try await ChannelAPI(serverURL: testingURL).catalog()
                result = Self.connectionSummary(serverURL: testingURL, channelCount: catalog.channels.count)
                resultIsError = false
            } catch {
                result = "Couldn't connect to \(testingURL): \(error.localizedDescription)"
                resultIsError = true
            }
        }
    }

    static func connectionSummary(serverURL: String, channelCount: Int) -> String {
        let noun = channelCount == 1 ? "channel" : "channels"
        return "Connected to \(serverURL). \(channelCount) \(noun) available."
    }
}
