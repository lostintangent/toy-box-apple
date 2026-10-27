import ChannelClient
import ChannelIntelligence
import SwiftUI
import ToyBoxUI

struct SettingsView: View {
    private struct ServerChange: Identifiable {
        let id = UUID()
        let previous: String
        let address: String
    }

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.channelIntelligence) private var intelligence
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage(TranscriptIntelligenceSettings.summarizesNewMessages) private var summarizesNewMessages = true
    @AppStorage(TranscriptIntelligenceSettings.describesImages) private var describesImages = true
    @ViewState private var connection = ServerConnectionProbe()
    @ViewState private var availability: IntelligenceAvailability?
    @ViewState private var pendingChange: ServerChange?
    @ViewState private var useFailure: String?
    @ViewState private var isApplying = false

    var body: some View {
        Form {
            ServerConnectionSection(connection: connection, requiresTest: false, currentServer: model.serverURL,
                                    onUse: requestServerChange, useFailure: $useFailure)
                .disabled(isApplying)
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { value in Text(value.title).tag(value) }
                }
            }
            NotificationSettingsSection(notifications: model.notifications,
                                        registrationError: model.notifications.registrationError,
                                        retryRegistration: model.notifications.retryRegistration)
            intelligenceSection
            Section("About") {
                LabeledContent("App", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                               ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unavailable")
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                               as? String ?? "Unavailable")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                               as? String ?? "Unavailable")
                Text("Toy Box connects to your server while open. Notifications and followed-channel updates can arrive while it is closed. Keep the Mac running your Toy Box server awake.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("settings-form")
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .close) { model.isSettingsPresented = false }
                    .accessibilityLabel("Close Settings")
                    .disabled(isApplying)
            }
        }
        .onAppear {
            connection.address = model.serverURL
            availability = intelligence.availability
        }
        .onDisappear { connection.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                availability = intelligence.availability
                Task { await model.notifications.refreshAuthorization() }
            }
            else { connection.cancel() }
        }
        .task { await model.notifications.refreshAuthorization() }
        .sheet(item: $pendingChange) { change in
            NavigationStack {
                Form {
                    Section {
                        Text("Live connections to the current server will close. Drafts stay saved separately for each server.")
                    }
                    Section {
                        serverAddress("Current Server", address: change.previous)
                        serverAddress("New Server", address: change.address)
                    }
                }
                .font(.body)
                .foregroundStyle(.primary)
                .navigationTitle("Switch Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { pendingChange = nil }
                            .disabled(isApplying)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Switch") {
                            pendingChange = nil
                            apply(change)
                        }
                        .disabled(isApplying)
                    }
                }
            }
            .presentationDetents([.large])
            .presentationSizing(.form)
            .interactiveDismissDisabled(isApplying)
        }
    }

    private func serverAddress(_ title: String, address: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(address).textSelection(.enabled)
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

    private func requestServerChange() {
        guard connection.validationError == nil else { return }
        pendingChange = ServerChange(previous: model.serverURL, address: connection.address)
    }

    private func apply(_ change: ServerChange) {
        guard !isApplying else { return }
        isApplying = true
        useFailure = nil
        Task {
            defer { isApplying = false }
            do {
                try model.switchServer(to: change.address, replacing: change.previous)
                connection.address = model.serverURL
                connection.cancel()
                let catalog = model.catalog
                await model.refreshCatalog()
                guard model.catalog === catalog else { return }
                useFailure = catalog?.error
            } catch { useFailure = error.localizedDescription }
        }
    }
}
