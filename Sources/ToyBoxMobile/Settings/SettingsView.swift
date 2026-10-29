import ChannelClient
import ChannelIntelligence
import ChannelKit
import SwiftUI
import ToyBoxUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.channelIntelligence) private var intelligence
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage(TranscriptIntelligenceSettings.summarizesNewMessages) private var summarizesNewMessages = true
    @AppStorage(TranscriptIntelligenceSettings.describesImages) private var describesImages = true
    @ViewState private var connection = ServerConnectionProbe()
    @ViewState private var availability: IntelligenceAvailability?
    @ViewState private var switchFailure: String?
    @ViewState private var isSwitching = false

    init(connection: ServerConnectionProbe = ServerConnectionProbe()) {
        _connection = ViewState(initialValue: connection)
    }

    var body: some View {
        Form {
            ServerConnectionSection(
                connection: connection, placeholder: "Required",
                footer: "Use your server's address, including its port and any path prefix. Toy Box switches to it once the test connects.",
                currentServer: model.serverURL, isSwitching: isSwitching, failure: $switchFailure)
                .disabled(isSwitching)
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { value in Text(value.title).tag(value) }
                }
            }
            NotificationSettingsSection(notifications: model.notifications)
            intelligenceSection
            Section("About") {
                LabeledContent("App", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                               ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unavailable")
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                               as? String ?? "Unavailable")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                               as? String ?? "Unavailable")
                Text("Toy Box connects to your server while open. Notifications and followed-channel updates can arrive while it is closed. Keep the computer running your Toy Box server awake.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("settings-form")
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .close) { model.isSettingsPresented = false }
                    .accessibilityLabel("Close Settings")
                    .disabled(isSwitching)
            }
        }
        .interactiveDismissDisabled(isSwitching)
        .onAppear {
            connection.address = model.serverURL
            availability = intelligence.availability
        }
        .onDisappear { connection.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { availability = intelligence.availability }
            else { connection.cancel() }
        }
        .task { await model.notifications.refreshAuthorization() }
        .onChange(of: connectedServer) { _, server in
            if let server { switchIfNeeded(to: server) }
        }
    }

    private var intelligenceSection: some View {
        Section {
            Toggle(isOn: $summarizesNewMessages) {
                Text("Summarize new messages")
                if availability == .available {
                    Text("When you return to a busy channel, a summary appears above the new messages. Made on this iPhone.")
                }
            }
            Toggle(isOn: $describesImages) {
                Text("Describe images for VoiceOver")
                if availability == .available {
                    Text("While VoiceOver is running, images get descriptions made on this iPhone.")
                }
            }
        } header: {
            Text("On-device Intelligence")
        } footer: {
            if case .unavailable(let reason) = availability {
                Text(Self.unavailableText(reason))
            }
        }
        .disabled(availability?.isAvailable != true)
    }

    static func unavailableText(_ reason: IntelligenceUnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This iPhone doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in Settings to use these. Open Settings and choose Apple Intelligence & Siri."
        case .modelNotReady: "Apple Intelligence is getting ready. Try again later."
        case .unsupportedLanguage: "Apple Intelligence doesn't support your iPhone's language yet."
        }
    }

    private var connectedServer: URL? {
        guard case .connected(let url, _)? = connection.phase else { return nil }
        return url
    }

    /// A successful test is the switch. Testing the server already in use only confirms it.
    private func switchIfNeeded(to server: URL) {
        guard !isSwitching, ChannelWaitingRequest.normalizedServer(server.absoluteString)
                != ChannelWaitingRequest.normalizedServer(model.serverURL) else { return }
        isSwitching = true
        switchFailure = nil
        Task {
            defer { isSwitching = false }
            do {
                try model.switchServer(to: server.absoluteString, replacing: model.serverURL)
                let catalog = model.catalog
                await model.refreshCatalog()
                guard model.catalog === catalog else { return }
                switchFailure = catalog?.phase.message
            } catch { switchFailure = error.localizedDescription }
        }
    }
}
