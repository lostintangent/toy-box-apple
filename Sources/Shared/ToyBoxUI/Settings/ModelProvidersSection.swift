import ToyBoxClient
import ToyBoxKit
import SwiftUI

/// A server's model providers in the server's order: each one's version, then its plan and how much
/// of each limit it has used, or why it isn't ready, then Check for Updates and the server's Restart
/// once an update installs something new. The page showing it calls `ServerProviders.appear()`, and a
/// server that lists no providers shows no section. See Model Providers in docs/spec.md.
public struct ModelProvidersSection: View {
    let providers: ServerProviders
    /// The server's release, whose Restart runs the versions an update installed.
    let update: ServerUpdate

    public init(_ providers: ServerProviders, update: ServerUpdate) {
        self.providers = providers
        self.update = update
    }

    public var body: some View {
        if !providers.entries.isEmpty {
            Section {
                ForEach(providers.entries) { entry in
                    ModelProviderRow(entry: entry)
                }
                updates
            } header: {
                Text("Model Providers")
            } footer: {
                #if os(iOS)
                if let message = providers.restartMessage { Text(message) }
                #endif
            }
        }
    }

    /// Only a server with an installed release can restart onto the versions an update installed.
    private var offersRestart: Bool {
        providers.restartMessage != nil && update.version?.installedVersion != nil
    }

    #if os(macOS)
    /// A bar under the providers, led by the restart sentence once an update installs something new.
    @ViewBuilder private var updates: some View {
        let message = providers.restartMessage
        if providers.offersUpdateCheck || message != nil {
            HStack(spacing: 8) {
                if let message { Text(message).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                if offersRestart {
                    Button("Restart") { Task { await update.restart() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!update.canRestart)
                }
                if providers.offersUpdateCheck {
                    Button("Check for Updates") { Task { await providers.checkForUpdates() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(providers.isCheckingForUpdates)
                        // The server list's Check for Updates shares the tab.
                        .accessibilityLabel("Check for model provider updates")
                }
            }
        }
    }
    #else
    /// Rows after the providers, with the restart sentence as the section's footer.
    @ViewBuilder private var updates: some View {
        if providers.offersUpdateCheck {
            let isChecking = providers.isCheckingForUpdates
            Button("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                Task { await providers.checkForUpdates() }
            }
            .disabled(isChecking)
            // A disabled Form button keeps its tinted icon, so it dims the whole row itself.
            .foregroundStyle(isChecking ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .accessibilityLabel("Check for model provider updates")
        }
        if offersRestart {
            Button("Restart", systemImage: "arrow.clockwise") { Task { await update.restart() } }
                .disabled(!update.canRestart)
                .foregroundStyle(update.canRestart ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }
    #endif
}

private struct ModelProviderRow: View {
    let entry: ServerProviders.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header.accessibilityElement(children: .combine)
            if case .failed(let words)? = entry.update {
                // Not a Label, which a Form gives its wide icon column.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    Text(words).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                #if os(macOS)
                .lineLimit(1)
                .help(words)
                #else
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                #endif
            }
            if entry.provider.enabled, entry.provider.status == .failed, let error = entry.provider.error {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            switch entry.usage {
            case .loading?:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading usage…")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            case .loaded(let subscription)?:
                if !subscription.limits.isEmpty { ModelProviderLimits(limits: subscription.limits) }
            case .none?, nil:
                EmptyView()
            }
        }
    }

    /// The name with the version slot after it, then the plan or status at the end. On the phone,
    /// the version slot drops to its own line under the name when the three can't share one.
    @ViewBuilder private var header: some View {
        #if os(macOS)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.provider.name)
            version
            Spacer(minLength: 8)
            if let end { Text(end).foregroundStyle(.secondary) }
        }
        #else
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.provider.name)
                version
                Spacer(minLength: 8)
                if let end { Text(end).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.provider.name)
                    Spacer(minLength: 8)
                    if let end { Text(end).foregroundStyle(.secondary) }
                }
                version
            }
        }
        #endif
    }

    /// The provider's version, or a spinner while it updates, or how its last update ended. A
    /// failed update keeps the version, with its words under the name.
    @ViewBuilder private var version: some View {
        Group {
            switch entry.update {
            case .updating?:
                // Drawn over a line of the name's font, so it centers on that line and the row
                // keeps its height. The phone's spinner reports a frame much taller than it draws.
                Text(verbatim: "00").font(.body).hidden()
                    .overlay { ProgressView().controlSize(.small) }
                    .accessibilityRepresentation { Text("Updating") }
            case .upToDate?:
                Text("Up to date")
            case .updated(let from?, let to)?:
                Text("\(from) → \(to)").accessibilityLabel("\(from), \(to) after restart")
            case .updated(nil, let to)?:
                Text("→ \(to)").accessibilityLabel("\(to) after restart")
            case .failed?, nil:
                if let version = entry.provider.version { Text(version) }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    /// The end of the row: the plan once it's read, or why the provider isn't ready. A provider that
    /// isn't installed can't be turned on, so it says so even while it's off.
    private var end: String? {
        let provider = entry.provider
        if provider.status == .unavailable { return "Not Installed" }
        if !provider.enabled { return "Off" }
        switch provider.status {
        case .ready:
            guard case .loaded(let subscription)? = entry.usage, !subscription.planName.isEmpty else { return nil }
            return subscription.planName
        case .signedOut: return "Signed Out"
        case .failed: return "Failed"
        case .unavailable: return "Not Installed"
        }
    }
}

/// One line for each of a plan's limits, like the web: its name, a bar, its percent and when it resets.
private struct ModelProviderLimits: View {
    let limits: [ModelProviderLimit]
    @ScaledMetric(relativeTo: .subheadline) private var barWidth: CGFloat = 80

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            ForEach(limits, id: \.name) { limit in
                GridRow {
                    Text(limit.name).foregroundStyle(.secondary)
                    ProgressView(value: min(max(limit.usedPercent, 0), 100), total: 100)
                        .frame(width: barWidth)
                        // The percent beside it says the same.
                        .accessibilityHidden(true)
                    Text(limit.usedPercent / 100, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    if let resetsAt = limit.resetsAt {
                        Text(resetsAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}
