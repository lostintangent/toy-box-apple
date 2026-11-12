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
        .task(id: model.catalogs.map(\.api.baseURL)) {
            await withTaskGroup { group in
                for catalog in model.catalogs { group.addTask { await catalog.update.refresh() } }
            }
        }
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
            if model.catalogs.offersUpdateCheck {
                let isChecking = model.catalogs.isCheckingForUpdates
                Button("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await model.catalogs.checkForUpdates() }
                }
                .disabled(isChecking)
                // A disabled Form button keeps its tinted icon, so it dims the whole row itself.
                .foregroundStyle(isChecking ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
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

/// A server's dot and name, then its host, or that it can't connect, then its release. A failed check
/// or restart reads under the name. See Updating a server in docs/spec.md.
private struct ServerRow: View {
    let catalog: ChannelCatalogStore

    var body: some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        let host = SidebarFooter.server(catalog.api.baseURL.absoluteString)
        let update = catalog.update
        let isConnected = catalog.phase.failure == nil
        let failure: String? = if case .failed(let words)? = update.outcome { words } else { nil }
        // The dot already says it can't connect, so the row says so only when it shows nothing else.
        let detail: String? = if !isConnected {
            failure == nil && (update.phase == nil || update.phase == .idle) ? "Can't connect" : nil
        } else {
            catalog.name == host ? nil : host
        }
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Self.dotSpacing) {
                    Circle().fill(footer.dot).frame(width: Self.dotSize, height: Self.dotSize)
                        .accessibilityHidden(true)
                    Text(catalog.name).lineLimit(1)
                }
                if let failure {
                    Text("\(Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)) \(failure)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, Self.dotSize + Self.dotSpacing)
                }
            }
            Spacer(minLength: 0)
            if let detail {
                Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            ServerUpdateStatus(update: update, showsVersion: isConnected).fixedSize()
        }
        .accessibilityValue(footer.accessibilityValue)
    }

    private static let dotSize: CGFloat = 8
    private static let dotSpacing: CGFloat = 10
}

/// The end of a server's row: its version, a spinner while it checks, Up to date after a check that
/// found nothing newer, or Restart once a newer release is installed.
private struct ServerUpdateStatus: View {
    let update: ServerUpdate
    /// A server that can't connect says so instead.
    let showsVersion: Bool

    var body: some View {
        switch update.phase {
        case .checking?:
            ProgressView()
        case .restarting?:
            HStack(spacing: 8) {
                Text("Restarting…").foregroundStyle(.secondary)
                ProgressView()
            }
        case .restartPending?:
            Button("Restart") { Task { await update.restart() } }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        case .idle?, nil:
            if update.outcome == .upToDate {
                Text("Up to date").foregroundStyle(.secondary)
            } else if showsVersion, let version = update.version?.version {
                Text(version).foregroundStyle(.secondary)
            }
        }
    }
}
