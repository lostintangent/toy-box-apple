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
        // Every server again as one connects, so one that was down when Settings opened shows.
        .task(id: model.catalogs.filter { $0.phase == .connected }.map(\.api.baseURL)) {
            await model.catalogs.refreshServers()
        }
    }

    /// Each server with its dot and name, in the order the list shows them. Removing one asks first.
    private var servers: some View {
        Section {
            ForEach(model.catalogs, id: \.api.baseURL) { catalog in
                NavigationLink(value: ServerRoute(catalog: catalog)) { ServerRow(catalog: catalog) }
                    // No items, so no menu, while the server can't restart.
                    .contextMenu {
                        if catalog.update.canRestart {
                            Button("Restart", systemImage: "arrow.clockwise") {
                                Task { await catalog.update.restart() }
                            }
                        }
                    }
            }
            .onMove { model.servers.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { removal = $0.first.map { model.catalogs[$0] } }
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
        }
        .confirmationDialog("Remove \(removal?.name ?? "this server")?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), titleVisibility: .visible, presenting: removal) { catalog in
            Button("Remove Server", role: .destructive) { model.servers.remove(catalog) }
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

/// A server's dot and name, `link` when it's linked, then that it can't connect, or its release. A
/// failed check or restart reads under the name, up to three lines, and VoiceOver reads all of it. See
/// Updating a server and Linking servers in docs/spec.md.
private struct ServerRow: View {
    let catalog: ChannelCatalogStore
    @Environment(AppModel.self) private var model

    var body: some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        let update = catalog.update
        let isConnected = catalog.phase.failure == nil
        let isLinked = !model.catalogs.linkedServers(of: catalog).isEmpty
        let failure: String? = if case .failed(let words)? = update.outcome { words } else { nil }
        // The dot already says it can't connect, so the row says so only when it shows nothing else.
        let cantConnect = !isConnected && failure == nil && update.phase != .checking && update.phase != .reconnecting
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Self.dotSpacing) {
                    Circle().fill(footer.dot).frame(width: Self.dotSize, height: Self.dotSize)
                        .accessibilityHidden(true)
                    HStack(spacing: 6) {
                        Text(catalog.name).lineLimit(1)
                        if isLinked {
                            Image(systemName: "link").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    // The dot's meaning, read once for the row.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(catalog.name)
                    .accessibilityValue(isLinked ? "\(footer.accessibilityValue), linked" : footer.accessibilityValue)
                }
                if let failure {
                    Text("\(Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)) \(failure)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.leading, Self.dotSize + Self.dotSpacing)
                        .accessibilityLabel(failure)
                }
            }
            Spacer(minLength: 0)
            if cantConnect {
                Text("Can't connect").foregroundStyle(.secondary).lineLimit(1)
            }
            ServerUpdateStatus(update: update, showsVersion: isConnected).fixedSize()
        }
    }

    private static let dotSize: CGFloat = 8
    private static let dotSpacing: CGFloat = 10
}

/// The end of a server's row: its version, a spinner while it checks or reconnects, Up to date after
/// a check that found nothing newer, or Restart once a newer release is installed and while the
/// server can restart.
private struct ServerUpdateStatus: View {
    let update: ServerUpdate
    /// A server that can't connect says so instead.
    let showsVersion: Bool

    var body: some View {
        switch update.phase {
        case .checking?:
            ProgressView().accessibilityRepresentation { Text("Checking for updates") }
        case .reconnecting?:
            ProgressView().accessibilityRepresentation { Text("Reconnecting") }
        case .restartPending?:
            if update.canRestart {
                Button("Restart") { Task { await update.restart() } }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        case .idle?, nil:
            if update.outcome == .upToDate {
                Text("Up to date").foregroundStyle(.secondary)
            } else if showsVersion, let version = update.version?.version {
                Text(version).foregroundStyle(.secondary)
            }
        }
    }
}
