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
    @AppStorage(IntelligenceSettings.summarizesNewMessages) private var summarizesNewMessages = true
    @AppStorage(IntelligenceSettings.describesImages) private var describesImages = true
    @ViewState private var availability: IntelligenceAvailability?
    @ViewState private var addsServer = false
    @ViewState private var removal: ChannelCatalogStore?

    var body: some View {
        Form {
            servers
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
        .navigationDestination(for: ServerRoute.self) { ServerSettingsView(catalog: $0.catalog) }
        .navigationDestination(isPresented: $addsServer) { ServerSettingsView(catalog: nil) }
        .toolbar {
            if model.catalogs.count > 1 {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .close) { model.cover = nil }
                    .accessibilityLabel("Close Settings")
            }
        }
        .onAppear { availability = intelligence.availability }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { availability = intelligence.availability }
        }
        .task { await model.notifications.refreshAuthorization() }
    }

    /// Each server with its dot and name, in the order the list shows them. Removing one asks first,
    /// and the last can't be removed.
    private var servers: some View {
        Section {
            ForEach(model.catalogs, id: \.api.baseURL) { catalog in
                NavigationLink(value: ServerRoute(catalog: catalog)) { ServerRow(catalog: catalog) }
            }
            .onMove { model.moveServers(fromOffsets: $0, toOffset: $1) }
            .onDelete { removal = $0.first.map { model.catalogs[$0] } }
            .deleteDisabled(model.catalogs.count < 2)
            Button("Add Server", systemImage: "plus") { addsServer = true }
        } header: {
            Text("Servers")
        } footer: {
            if model.catalogs.count > 1 {
                Text("Drag to reorder in Edit. The list shows servers in this order.")
            }
        }
        .confirmationDialog("Remove \(removal?.name ?? "this server")?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), titleVisibility: .visible, presenting: removal) { catalog in
            Button("Remove Server", role: .destructive) { model.removeServer(catalog) }
        } message: { _ in
            Text("Toy Box disconnects from it and removes its channels from this iPhone. Drafts stay saved, so adding it back finds them.")
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
}

/// A server's dot and name, then its host, or that it can't connect.
private struct ServerRow: View {
    let catalog: ChannelCatalogStore

    var body: some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        let host = SidebarFooter.server(catalog.api.baseURL.absoluteString)
        let detail = catalog.phase.failure != nil ? "Can't connect" : catalog.name == host ? nil : host
        LabeledContent {
            if let detail { Text(detail).lineLimit(1).truncationMode(.middle) }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(footer.dot).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(catalog.name).lineLimit(1)
            }
        }
        .accessibilityValue(footer.accessibilityValue)
    }
}
