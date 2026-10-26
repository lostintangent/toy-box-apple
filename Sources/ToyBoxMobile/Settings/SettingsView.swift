import ChannelClient
import ChannelIntelligence
import SwiftUI
import ToyBoxUI

struct SettingsView: View {
    private struct ServerChange {
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
            intelligenceSection
            Section("About") {
                LabeledContent("App", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                               ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unavailable")
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                               as? String ?? "Unavailable")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                               as? String ?? "Unavailable")
                Text("Toy Box connects while this app is in the foreground. Keep your Mac awake with Toy Box running. This release doesn't monitor channels or deliver push notifications after you leave.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { model.isSettingsPresented = false }.disabled(isApplying)
            }
        }
        .onAppear {
            connection.address = model.serverURL
            availability = intelligence.availability
        }
        .onDisappear { connection.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { availability = intelligence.availability }
            else { connection.cancel() }
        }
        .alert("Switch Toy Box servers?", isPresented: Binding(
            get: { pendingChange != nil },
            set: { if !$0 { pendingChange = nil } }
        ), presenting: pendingChange) { change in
            Button("Switch Server") { apply(change) }
            Button("Cancel", role: .cancel) {}
        } message: { change in
            Text("Live connections to \(change.previous) will close. Switch to \(change.address)? Drafts stay saved separately for each server.")
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
